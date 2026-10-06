local M = {}
local exec_mod = require("herdr-nvim.exec")

function M.list(exec)
  exec = exec or exec_mod.default_exec
  local r = exec({ "herdr", "agent", "list" })
  if r.code ~= 0 then
    return nil, "herdr agent list failed: " .. (r.stderr ~= "" and r.stderr or ("exit " .. r.code))
  end
  local ok, decoded = pcall(vim.json.decode, r.stdout)
  if not ok or type(decoded) ~= "table" then return nil, "herdr agent list: unparseable JSON" end
  local raw = (decoded.result or {}).agents
  if type(raw) ~= "table" then return nil, "herdr agent list: missing agents" end
  local function nonempty(s) return type(s) == "string" and s ~= "" and s or nil end
  local out = {}
  local here = vim.env.HERDR_WORKSPACE_ID
  for _, a in ipairs(raw) do
    if nonempty(a.agent) and (not here or a.workspace_id == here) then
      table.insert(out, {
        pane_id = a.pane_id,
        terminal_id = a.terminal_id,
        workspace_id = a.workspace_id,
        tab_id = a.tab_id,
        name = nonempty(a.name),
        kind = a.agent,
        status = a.agent_status or "unknown",
        cwd = nonempty(a.foreground_cwd) or nonempty(a.cwd) or "",
        title = nonempty(a.name) or nonempty(a.title) or nonempty(a.terminal_title) or a.agent,
        agent_session = type(a.agent_session) == "table" and vim.deepcopy(a.agent_session) or nil,
        launch_pending = a.launch_pending == true,
      })
    end
  end
  table.sort(out, function(x, y) return x.title < y.title end)
  return out
end

-- Resolve the one agent to target without a picker, or nil when it's ambiguous.
-- `list` is already workspace-scoped by M.list. Narrowest unambiguous match wins:
--   1. a single agent sharing the current tab (HERDR_TAB_ID) — the sibling pane,
--      same convention the file picker uses to find "the agent in this tab";
--   2. otherwise, a lone agent in the workspace.
-- Anything ambiguous (2+ candidates) returns nil so the caller shows the picker.
function M.resolve(list)
  if #list == 1 then return list[1] end
  local tab = vim.env.HERDR_TAB_ID
  if tab then
    local in_tab = {}
    for _, a in ipairs(list) do
      if a.tab_id == tab then table.insert(in_tab, a) end
    end
    if #in_tab == 1 then return in_tab[1] end
  end
  return nil
end

function M.display(agent)
  -- Keep full cwd and pane/tab identity: multiple Pi agents can share a repo
  -- basename, or even the exact same cwd, without being interchangeable.
  local identity = agent.name and (agent.kind .. " (" .. agent.name .. ")") or agent.kind
  return string.format("%s · %s · %s · %s · %s", identity, agent.status,
    agent.cwd or "", agent.tab_id or "?", agent.pane_id or "?")
end

return M
