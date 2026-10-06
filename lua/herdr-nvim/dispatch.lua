local M = {}
local exec_mod = require("herdr-nvim.exec")
local api = require("herdr-nvim.api")

local function safe_text(text)
  if type(text) ~= "string" or text == "" then return false end
  -- Pi treats LF as editor content. Reject all other C0 controls (including
  -- TAB, CR and ESC/bracket-paste delimiters), DEL and C1.
  return not text:find("[%z\1-\9\11-\31\127]") and not text:find("\194[\128-\159]")
end

local function acceptable(target)
  -- Herdr's "done" is idle with an unseen completion, not a running dialog.
  return target.launch_pending ~= true and
    (target.agent_status == "idle" or target.agent_status == "working" or target.agent_status == "done")
end

local function cwd_of(target)
  if type(target.foreground_cwd) == "string" and target.foreground_cwd ~= "" then return target.foreground_cwd end
  return type(target.cwd) == "string" and target.cwd ~= "" and target.cwd or nil
end

local function same_identity(expected, actual, pane_id)
  local kind = expected.kind or expected.agent
  if type(expected.terminal_id) ~= "string" or expected.terminal_id == "" or
    type(kind) ~= "string" or kind == "" or kind == "unknown" then return false end
  return expected.pane_id == pane_id and actual.pane_id == pane_id and
    expected.terminal_id == actual.terminal_id and kind == actual.agent and
    type(expected.workspace_id) == "string" and expected.workspace_id == actual.workspace_id and
    type(expected.tab_id) == "string" and expected.tab_id == actual.tab_id and
    cwd_of(expected) == cwd_of(actual) and
    vim.deep_equal(expected.agent_session, actual.agent_session)
end

-- Keep the pane-id API. UI callers pass opts.agent, the identity captured when
-- selecting the target; pane-only callers resolve and validate at invocation.
-- request is injectable for tests; no shell ever sees the draft text.
function M.send(pane_id, text, opts, exec, request)
  opts = opts or {}
  exec = exec or exec_mod.default_exec
  request = request or api.request
  if type(text) == "string" and text:find("\t", 1, true) then
    return false, "draft contains tabs; replace tabs with spaces before pasting (Herdr does not expose bracket-paste mode)"
  end
  if not safe_text(text) then return false, "refusing empty text or unsafe control characters in agent draft" end

  local result, err = request("agent.get", { target = pane_id })
  local agent = result and result.agent
  if type(agent) ~= "table" then return false, err or "agent identity unavailable" end
  local expected = opts.agent or agent
  if not same_identity(expected, agent, pane_id) then return false, "selected agent was replaced or moved; select it again" end
  if not acceptable(agent) then return false, "agent is blocked, unknown or not ready; refusing input" end

  -- Validate the pane separately, immediately before input. A pane id can now
  -- host another terminal/session, or the agent can enter a dialog meanwhile.
  result, err = request("pane.get", { pane_id = pane_id })
  local pane = result and result.pane
  if type(pane) ~= "table" then return false, err or "pane identity unavailable" end
  if not same_identity(agent, pane, pane_id) then return false, "pane no longer hosts the selected agent" end
  if not acceptable(pane) then return false, "pane is blocked or unknown; refusing input" end

  if opts.submit then
    -- Explicit opt-in API remains: Herdr also checks foreground/blocked state.
    local r = exec({ "herdr", "agent", "prompt", pane_id, text })
    if r.code ~= 0 then
      return false, "herdr agent prompt failed: " .. (r.stderr ~= "" and r.stderr or ("exit " .. r.code))
    end
  else
    -- Supported paste transport, NOT pane.send_text's raw PTY bytes. Empty
    -- keys is essential: no Enter/submit is appended, including multiline text.
    result, err = request("pane.send_input", { pane_id = pane_id, text = text, keys = {} })
    if not result or result.type ~= "ok" then return false, "herdr paste failed: " .. (err or "invalid acknowledgement") end
  end
  return true
end

return M
