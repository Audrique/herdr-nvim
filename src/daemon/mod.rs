//! The per-tab headless nvim daemon: spawning it and attaching the sidebar's
//! UI to it. Its registry and shutdown live in `registry`, the herdr close
//! hooks in `events`, and the `herdr-nvim daemons` command in `inventory`.

pub(crate) mod events;
pub(crate) mod inventory;
pub(crate) mod registry;

use std::{
    env, fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread::sleep,
    time::{Duration, Instant},
};

use anyhow::{bail, Context, Result};

use crate::{
    config::{Config, Sidebar},
    state::TabId,
};

use registry::socket_path;

const HEALTH_POLL_INTERVAL: Duration = Duration::from_millis(100);
const HEALTH_POLL_TIMEOUT: Duration = Duration::from_secs(10);

const READY_POLL_INTERVAL: Duration = Duration::from_millis(50);
// Short: only waits out the tail of an already-in-flight `maneuver::open`,
// never a fresh operation, so a stale size is preferable to a hung-looking pane.
const READY_POLL_TIMEOUT: Duration = Duration::from_secs(2);

/// Build a `Command` invoking the configured nvim binary with the configured
/// environment overrides. Shared by every call site that talks to a daemon
/// (health checks, `--remote-ui` attach, `--remote-send` quit, `--remote`
/// open) so both `sidebar.nvim_bin` and `sidebar.nvim_env` apply uniformly,
/// not just to spawning the daemon itself.
pub(crate) fn nvim_cmd(sidebar: &Sidebar) -> Command {
    let mut command = Command::new(&sidebar.nvim_bin);
    for (key, value) in sidebar.env_override() {
        command.env(key, value);
    }
    command
}

/// Ensure a per-tab headless nvim daemon is listening on its socket,
/// returning the socket path. If a healthy daemon already exists this is a
/// no-op; otherwise a detached daemon is spawned and polled until healthy.
pub fn ensure_daemon(
    tab: &str,
    plugin_root: &Path,
    config: &Config,
    cwd: &Path,
) -> Result<PathBuf> {
    let socket = socket_path(tab);
    if remote_expr(&socket, "1+1", &config.sidebar).as_deref() == Some("2") {
        // A responsive but broken/unready plugin is NOT a dead socket. Never
        // unlink it or start a competing daemon; surface its bootstrap error.
        wait_daemon_ready(tab, &socket, &config.sidebar)?;
        // Also (re)register an already-running daemon, so one spawned before
        // the Windows marker existed still becomes discoverable.
        #[cfg(windows)]
        registry::register_daemon(tab)?;
        return Ok(socket);
    }

    #[cfg(not(windows))]
    {
        let dir = socket
            .parent()
            .with_context(|| format!("socket path has no parent: {}", socket.display()))?;
        fs::create_dir_all(dir)
            .with_context(|| format!("failed to create runtime directory {}", dir.display()))?;
        // A stale (dead) socket file would make `nvim --listen` fail to bind.
        // We only get here after the health check failed, so any file present
        // is dead.
        crate::state::remove_file_if_exists(&socket)?;
    }

    spawn_daemon(tab, &socket, plugin_root, &config.sidebar, cwd)?;
    #[cfg(windows)]
    registry::register_daemon(tab)?;

    wait_daemon_ready(tab, &socket, &config.sidebar)?;
    Ok(socket)
}

fn wait_daemon_ready(tab: &str, socket: &Path, sidebar: &Sidebar) -> Result<()> {
    let deadline = Instant::now() + HEALTH_POLL_TIMEOUT;
    loop {
        if daemon_healthy(socket, sidebar)? {
            return Ok(());
        }
        if Instant::now() >= deadline {
            bail!(
                "nvim daemon for tab {tab} did not become plugin-ready within {}s",
                HEALTH_POLL_TIMEOUT.as_secs()
            );
        }
        sleep(HEALTH_POLL_INTERVAL);
    }
}

fn spawn_daemon(
    tab: &str,
    socket: &Path,
    plugin_root: &Path,
    sidebar: &Sidebar,
    cwd: &Path,
) -> Result<()> {
    // The pre-init `set rtp+=` below is not enough on its own: configs that
    // rebuild runtimepath from scratch during startup (any plugin manager with
    // an rtp reset, e.g. lazy.nvim's default `performance.rtp.reset = true`)
    // drop our appended path before VimEnter fires. So the VimEnter callback
    // re-appends the plugin root to rtp
    // *after* the user's config has loaded, then requires the plugin. The whole
    // pcall records errors for the readiness probe instead of swallowing them.
    // bootstrap() preserves any setup already performed by the user's config.
    let vim_enter = format!(
        "lua vim.api.nvim_create_autocmd('VimEnter',{{callback=function() \
         local ok,err=pcall(function() vim.opt.rtp:append({root:?}); \
         assert(require('herdr-nvim').bootstrap(),'plugin readiness check failed') end); \
         if not ok then vim.g.herdr_nvim_bootstrap_error=tostring(err); \
         vim.notify('herdr-nvim bootstrap failed: '..tostring(err),vim.log.levels.ERROR) end end}})",
        root = plugin_root.display().to_string()
    );
    // Plumb the tab's identity into the daemon explicitly. The daemon is
    // per-tab and persistent, and it may be spawned through a plugin pane (the
    // `pick-file` picker) whose only context is `HERDR_PLUGIN_CONTEXT_JSON` --
    // herdr does not export the flat `HERDR_WORKSPACE_ID`/`HERDR_TAB_ID` into a
    // plugin pane. Relying on inherited env therefore leaves the daemon (and
    // thus `agents.lua`) with no workspace/tab scope on that path, so the agent
    // picker opens even for an unambiguous target (issue #20). Setting them here
    // from the tab id we already have makes scoping deterministic regardless of
    // which pane first spawned the daemon.
    let workspace = TabId::new(tab).workspace().to_owned();

    let mut command = nvim_cmd(sidebar);
    command
        .arg("--headless")
        .arg("--listen")
        .arg(socket)
        .arg("--cmd")
        .arg(format!(
            "lua vim.opt.rtp:append({:?})",
            plugin_root.display().to_string()
        ))
        .arg("--cmd")
        .arg(&vim_enter)
        .env("HERDR_WORKSPACE_ID", &workspace)
        .env("HERDR_TAB_ID", tab)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    detach_command(&mut command);
    let child = command
        .spawn()
        .context("failed to spawn nvim daemon (is nvim installed?)")?;

    // Read the pid (useful for diagnostics) and drop the handle without waiting:
    // the daemon is now a session leader in its own session and keeps running,
    // tracked from here on only by its socket.
    let _pid = child.id();
    drop(child);
    Ok(())
}

/// Detach a child that must survive the pane process which launched it.
pub(crate) fn detach_command(command: &mut Command) {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;

        // SAFETY: the pre_exec closure only calls setsid(2), which is
        // async-signal-safe and does not touch shared parent state.
        unsafe {
            command.pre_exec(|| {
                extern "C" {
                    fn setsid() -> i32;
                }
                setsid();
                Ok(())
            });
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;

        // CREATE_NO_WINDOW keeps the headless daemon out of the user's console,
        // while CREATE_NEW_PROCESS_GROUP keeps it independent from the pane's
        // console process group. Unlike DETACHED_PROCESS, it still permits the
        // redirected standard handles used above.
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x00000200;
        command.creation_flags(CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP);
    }
}

fn daemon_healthy(socket: &Path, sidebar: &Sidebar) -> Result<bool> {
    // Pure readiness query: no setup(), option changes or keymap resets.
    const EXPR: &str = "luaeval(\"vim.json.encode((function() local err=vim.g.herdr_nvim_bootstrap_error; if err then return {error=err} end; local m=package.loaded['herdr-nvim']; return {ready=m~=nil and type(m.ready)=='function' and m.ready() or false} end)())\")";
    let Some(raw) = remote_expr(socket, EXPR, sidebar) else {
        return Ok(false);
    };
    let status: serde_json::Value = serde_json::from_str(&raw)
        .with_context(|| format!("invalid nvim plugin readiness response: {raw}"))?;
    if let Some(error) = status.get("error").and_then(serde_json::Value::as_str) {
        bail!("herdr-nvim plugin bootstrap failed: {error}");
    }
    Ok(status.get("ready").and_then(serde_json::Value::as_bool) == Some(true))
}

/// Evaluate a vimscript expression on the daemon via `--remote-expr`, returning
/// the trimmed stdout, or `None` if the daemon is unreachable.
pub(crate) fn remote_expr(socket: &Path, expr: &str, sidebar: &Sidebar) -> Option<String> {
    let output = nvim_cmd(sidebar)
        .arg("--headless")
        .arg("--server")
        .arg(socket)
        .arg("--remote-expr")
        .arg(expr)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

/// Quote `s` with single quotes, escaping any single quotes it already
/// contains (`'` -> `'\''`) -- used where a value is spliced into a command
/// executed by a shell (e.g. the nvim bin in doctor's `pane run` probe), not
/// just displayed, so it is always quoted unconditionally.
pub(crate) fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// Runs inside the sidebar pane: ensure the tab's daemon is up, then replace
/// this process with `nvim --remote-ui` attached to it.
///
/// The pane is spawned by herdr via `plugin pane open --entrypoint sidebar`
/// (non-interactive, no shell echo). herdr sets `HERDR_TAB_ID` for the pane so
/// it knows which tab's daemon to attach to, and the pane's own cwd (set via
/// `--cwd`) is where the daemon spawns.
pub fn sidebar_cmd() -> Result<()> {
    let tab = env::var("HERDR_TAB_ID")
        .context("herdr-nvim sidebar requires HERDR_TAB_ID (set by herdr for plugin panes)")?;
    let cwd = env::current_dir().context("herdr-nvim sidebar could not resolve its cwd")?;
    let plugin_root = plugin_root()?;
    let config = crate::config::load();
    let socket = ensure_daemon(&tab, &plugin_root, &config, &cwd)?;
    wait_for_layout_ready();

    attach_remote_ui(&socket, &config.sidebar)
}

#[cfg(unix)]
fn attach_remote_ui(socket: &Path, sidebar: &Sidebar) -> Result<()> {
    use std::os::unix::process::CommandExt;

    let error = nvim_cmd(sidebar)
        .arg("--server")
        .arg(socket)
        .arg("--remote-ui")
        .exec();
    Err(error).context("failed to exec nvim --remote-ui")
}

#[cfg(windows)]
fn attach_remote_ui(socket: &Path, sidebar: &Sidebar) -> Result<()> {
    let status = nvim_cmd(sidebar)
        .arg("--server")
        .arg(socket)
        .arg("--remote-ui")
        .status()
        .context("failed to run nvim --remote-ui")?;
    if !status.success() {
        bail!("nvim --remote-ui failed (exit {status})");
    }
    Ok(())
}

/// Blocks until `maneuver::open` signals layout is settled via
/// `HERDR_NVIM_READY_MARKER`, or `READY_POLL_TIMEOUT` elapses; a no-op if
/// the env var is unset, so this can never turn into an unconditional stall.
fn wait_for_layout_ready() {
    let Some(marker) = env::var_os("HERDR_NVIM_READY_MARKER").map(PathBuf::from) else {
        return;
    };
    let deadline = Instant::now() + READY_POLL_TIMEOUT;
    while !marker.exists() {
        if Instant::now() >= deadline {
            return;
        }
        sleep(READY_POLL_INTERVAL);
    }
    // Removal is best-effort: a leftover marker is nonced, unreachable by
    // later opens, and collected by `state::sweep_stale_markers`.
    let _ = fs::remove_file(&marker);
}

/// Locate the plugin root (the directory containing `lua/herdr-nvim`) so the
/// daemon can `require('herdr-nvim')`. `HERDR_NVIM_PLUGIN_ROOT` overrides;
/// otherwise walk up from this executable.
pub(crate) fn plugin_root() -> Result<PathBuf> {
    if let Some(root) = env::var_os("HERDR_NVIM_PLUGIN_ROOT") {
        return Ok(PathBuf::from(root));
    }
    let exe = env::current_exe().context("failed to resolve current executable path")?;
    let mut dir = exe.parent();
    while let Some(candidate) = dir {
        if candidate.join("lua").join("herdr-nvim").is_dir() {
            return Ok(candidate.to_path_buf());
        }
        dir = candidate.parent();
    }
    bail!("could not locate plugin root (set HERDR_NVIM_PLUGIN_ROOT)")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{nvim_available, TestDaemon, TestEnv};

    // Regression test for issue #20: a daemon spawned through the pick-file
    // picker inherits only HERDR_PLUGIN_CONTEXT_JSON (plugin panes get no flat
    // vars). The daemon must still end up with HERDR_WORKSPACE_ID/HERDR_TAB_ID
    // set from its tab id, so agents.lua can scope M.list()/resolve() and skip
    // the picker for an unambiguous target.
    #[test]
    fn daemon_gets_flat_identity_even_without_inherited_flat_vars() {
        if !nvim_available() {
            eprintln!("skipping: nvim not found on PATH");
            return;
        }
        let _env = TestEnv::new();
        let config = Config::default();

        // Mimic the picker/finisher parent env: JSON blob present, flat vars
        // absent -- exactly what the plugin pane hands down.
        env::remove_var("HERDR_WORKSPACE_ID");
        env::remove_var("HERDR_TAB_ID");
        env::set_var(
            "HERDR_PLUGIN_CONTEXT_JSON",
            r#"{"workspace_id":"w39","tab_id":"w39:t1"}"#,
        );
        let daemon = TestDaemon::spawn("w39:t1", &config);
        env::remove_var("HERDR_PLUGIN_CONTEXT_JSON");

        // What agents.lua reads inside the daemon must now be populated.
        assert_eq!(
            daemon.eval("$HERDR_WORKSPACE_ID"),
            "w39",
            "daemon must have HERDR_WORKSPACE_ID"
        );
        assert_eq!(
            daemon.eval("$HERDR_TAB_ID"),
            "w39:t1",
            "daemon must have HERDR_TAB_ID"
        );
    }

    #[test]
    fn ensure_daemon_spawns_then_is_idempotent_against_real_nvim() {
        if !nvim_available() {
            eprintln!("skipping: nvim not found on PATH");
            return;
        }
        let _env = TestEnv::new();
        let plugin_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let config = Config::default();

        let daemon = TestDaemon::spawn("wD", &config);
        #[cfg(not(windows))]
        assert!(
            daemon.socket.exists(),
            "socket file should exist after spawn"
        );

        let socket_again =
            ensure_daemon("wD", &plugin_root, &config, &plugin_root).expect("second ensure_daemon");
        assert_eq!(daemon.socket, socket_again);
        assert_eq!(
            daemon.eval("getpid()"),
            daemon.pid.to_string(),
            "second ensure_daemon must reuse the daemon, not spawn a new one"
        );
    }

    #[test]
    fn daemon_bootstrap_preserves_user_setup_and_maps() {
        if !nvim_available() {
            return;
        }
        let test_env = TestEnv::new();
        let config_dir = test_env.dir.join("xdg-config").join("hn-test");
        fs::create_dir_all(&config_dir).unwrap();
        fs::write(
            config_dir.join("init.lua"),
            concat!(
            "require('herdr-nvim').setup({keymaps=false,prefix='CUSTOM',clear_after_send=false})\n",
            "vim.keymap.set('n','CUSTOMs',\"<cmd>echo 'draft only'<cr>\")\n"
        ),
        )
        .unwrap();
        let config = Config {
            sidebar: Sidebar {
                nvim_env: vec!["NVIM_APPNAME=hn-test".into()],
                ..Default::default()
            },
            ..Default::default()
        };
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let socket = ensure_daemon("wP:t1", &root, &config, &root).unwrap();
        let pid = remote_expr(&socket, "getpid()", &config.sidebar)
            .unwrap()
            .parse()
            .unwrap();
        let daemon = TestDaemon {
            tab: TabId::new("wP:t1"),
            socket,
            pid,
        };
        assert!(daemon_healthy(&daemon.socket, &config.sidebar).unwrap());
        assert_eq!(
            daemon.eval("luaeval(\"require('herdr-nvim').config.prefix\")"),
            "CUSTOM"
        );
        assert_eq!(
            daemon.eval("luaeval(\"require('herdr-nvim').config.keymaps\")"),
            "false"
        );
        assert_eq!(
            daemon.eval("luaeval(\"require('herdr-nvim').config.clear_after_send\")"),
            "false"
        );
        assert!(daemon.eval("maparg('CUSTOMs','n')").contains("draft only"));
        assert_eq!(daemon.eval("maparg('CUSTOMS','n')"), "");
        ensure_daemon("wP:t1", &root, &config, &root).unwrap();
        assert_eq!(daemon.eval("getpid()"), pid.to_string());
        assert_eq!(
            daemon.eval("luaeval(\"require('herdr-nvim').config.prefix\")"),
            "CUSTOM"
        );
    }

    #[test]
    fn daemon_readiness_exposes_bootstrap_errors_without_replacing_live_socket() {
        if !nvim_available() {
            return;
        }
        let test_env = TestEnv::new();
        let config_dir = test_env.dir.join("xdg-config").join("hn-broken");
        fs::create_dir_all(&config_dir).unwrap();
        fs::write(
            config_dir.join("init.lua"),
            "package.preload['herdr-nvim']=function() error('test bootstrap failure') end\n",
        )
        .unwrap();
        let config = Config {
            sidebar: Sidebar {
                nvim_env: vec!["NVIM_APPNAME=hn-broken".into()],
                ..Default::default()
            },
            ..Default::default()
        };
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let socket = socket_path("wE:t1");
        #[cfg(not(windows))]
        fs::create_dir_all(socket.parent().unwrap()).unwrap();
        spawn_daemon("wE:t1", &socket, &root, &config.sidebar, &root).unwrap();
        // The failing bootstrap still leaves a responsive daemon; capture its
        // pid in the test guard before asserting anything so it cannot leak.
        let deadline = Instant::now() + HEALTH_POLL_TIMEOUT;
        let pid = loop {
            if let Some(pid) = remote_expr(&socket, "getpid()", &config.sidebar) {
                break pid.parse().unwrap();
            }
            assert!(Instant::now() < deadline, "test daemon did not answer");
            sleep(HEALTH_POLL_INTERVAL);
        };
        let daemon = TestDaemon {
            tab: TabId::new("wE:t1"),
            socket,
            pid,
        };
        let error = wait_daemon_ready("wE:t1", &daemon.socket, &config.sidebar).unwrap_err();
        assert!(
            error.to_string().contains("test bootstrap failure"),
            "{error}"
        );
        let error = ensure_daemon("wE:t1", &root, &config, &root).unwrap_err();
        assert!(
            error.to_string().contains("test bootstrap failure"),
            "{error}"
        );
        assert_eq!(
            daemon.eval("getpid()"),
            pid.to_string(),
            "a broken plugin must not replace a live daemon"
        );
    }

    #[test]
    fn nvim_cmd_applies_env_overrides_to_child() {
        let sidebar = Sidebar::default();
        let plain = nvim_cmd(&sidebar);
        assert!(
            plain.get_envs().all(|(key, _)| key != "NVIM_APPNAME"),
            "default sidebar must not override the environment"
        );

        let sidebar = Sidebar {
            nvim_env: vec![
                "NVIM_APPNAME=myapp".to_owned(),
                "HERDR_NVIM_EXTRA=1=2".to_owned(),
                "garbage-entry".to_owned(), // malformed: filtered out by env_override
            ],
            ..Default::default()
        };
        let cmd = nvim_cmd(&sidebar);
        let mut appname = None;
        let mut extra = None;
        for (key, value) in cmd.get_envs() {
            match key.to_str() {
                Some("NVIM_APPNAME") => appname = value.map(|v| v.to_string_lossy().into_owned()),
                Some("HERDR_NVIM_EXTRA") => extra = value.map(|v| v.to_string_lossy().into_owned()),
                _ => {}
            }
        }
        assert_eq!(appname.as_deref(), Some("myapp"));
        assert_eq!(extra.as_deref(), Some("1=2"), "value may contain an = sign");
    }
}
