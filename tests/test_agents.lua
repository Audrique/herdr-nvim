local agents = require("herdr-nvim.agents")

local fixture = vim.json.encode({
  id = "cli:agent:list",
  result = { agents = {
    { pane_id = "wA:p1", workspace_id = "wA", agent = "pi",
      agent_status = "idle", cwd = "/tmp/proj-a", terminal_title = "π - proj-a" },
    { pane_id = "wB:p2", workspace_id = "wB", agent = "claude",
      agent_status = "working", cwd = "/tmp/proj-b" },
  } },
})

local function fake_exec(out, code)
  return function(_) return { code = code or 0, stdout = out, stderr = "" } end
end

T.test("agents: parses list and normalizes fields", function()
  local previous = vim.env.HERDR_WORKSPACE_ID
  vim.env.HERDR_WORKSPACE_ID = nil
  local list, err = agents.list(fake_exec(fixture))
  vim.env.HERDR_WORKSPACE_ID = previous
  T.eq(err, nil)
  T.eq(#list, 2)
  local by_pane = {}
  for _, agent in ipairs(list) do by_pane[agent.pane_id] = agent end
  T.eq(by_pane["wA:p1"].kind, "pi")
  T.eq(by_pane["wA:p1"].status, "idle")
  T.eq(by_pane["wA:p1"].title, "π - proj-a")
  T.eq(by_pane["wB:p2"].title, "claude") -- falls back to kind
end)

T.test("agents: no current workspace sorts by title", function()
  vim.env.HERDR_WORKSPACE_ID = nil
  local list = agents.list(fake_exec(fixture))
  T.eq(list[1].pane_id, "wB:p2")
  T.eq(list[1].title, "claude")
  T.eq(list[2].pane_id, "wA:p1")
  T.eq(list[2].title, "π - proj-a")
end)

T.test("agents: current workspace excludes other workspaces", function()
  vim.env.HERDR_WORKSPACE_ID = "wB"
  local list = agents.list(fake_exec(fixture))
  vim.env.HERDR_WORKSPACE_ID = nil
  T.eq(#list, 1)
  T.eq(list[1].pane_id, "wB:p2")
end)

T.test("agents: CLI failure returns err", function()
  local list, err = agents.list(fake_exec("", 1))
  T.eq(list, nil)
  T.ok(err and err:match("herdr"))
end)

T.test("agents: unparseable JSON returns err", function()
  local list, err = agents.list(fake_exec("not json"))
  T.eq(list, nil)
  T.ok(err and err:match("unparseable"))
end)

T.test("agents: resolve returns the lone workspace agent", function()
  local a = agents.resolve({ { pane_id = "wA:p1", tab_id = "wA:t1" } })
  T.eq(a.pane_id, "wA:p1")
end)

T.test("agents: resolve picks the single agent in the current tab", function()
  local previous = vim.env.HERDR_TAB_ID
  vim.env.HERDR_TAB_ID = "wA:t2"
  local a = agents.resolve({
    { pane_id = "wA:p1", tab_id = "wA:t1" },
    { pane_id = "wA:p2", tab_id = "wA:t2" },
  })
  vim.env.HERDR_TAB_ID = previous
  T.eq(a.pane_id, "wA:p2")
end)

T.test("agents: resolve returns nil when the tab is ambiguous", function()
  local previous = vim.env.HERDR_TAB_ID
  vim.env.HERDR_TAB_ID = "wA:t1"
  local a = agents.resolve({
    { pane_id = "wA:p1", tab_id = "wA:t1" },
    { pane_id = "wA:p2", tab_id = "wA:t1" },
  })
  vim.env.HERDR_TAB_ID = previous
  T.eq(a, nil)
end)

T.test("agents: resolve returns nil when no tab context disambiguates", function()
  local previous = vim.env.HERDR_TAB_ID
  vim.env.HERDR_TAB_ID = nil
  local a = agents.resolve({
    { pane_id = "wA:p1", tab_id = "wA:t1" },
    { pane_id = "wB:p2", tab_id = "wB:t1" },
  })
  vim.env.HERDR_TAB_ID = previous
  T.eq(a, nil)
end)

T.test("agents: display row leads with agent kind", function()
  local row = agents.display({ kind = "pi", title = "π - a", status = "idle", cwd = "/x/y/proj" })
  T.eq(row, "pi · idle · /x/y/proj · ? · ?")
end)

T.test("agents: foreground cwd preferred, null/missing falls back, session identity retained", function()
  local previous = vim.env.HERDR_WORKSPACE_ID
  vim.env.HERDR_WORKSPACE_ID = nil
  local session = { agent = "pi", kind = "path", value = "/real-session.jsonl" }
  local list = agents.list(fake_exec(vim.json.encode({ result = { agents = {
    { pane_id = "wA:p1", tab_id = "wA:t1", terminal_id = "term-1", workspace_id = "wA", agent = "pi",
      name = "review", cwd = "/shell", foreground_cwd = "/work/proj", agent_session = session },
    { pane_id = "wA:p2", tab_id = "wA:t2", agent = "pi", cwd = "/other/proj", foreground_cwd = vim.NIL },
    { pane_id = "wA:p3", tab_id = "wA:t3", agent = "pi", cwd = "/fallback", foreground_cwd = "" },
    { pane_id = "wA:shell", tab_id = "wA:t1", cwd = "/shell" },
  } } })))
  vim.env.HERDR_WORKSPACE_ID = previous
  T.eq(#list, 3, "bare panes are not agent targets")
  local by_pane = {}
  for _, a in ipairs(list) do by_pane[a.pane_id] = a end
  T.eq(by_pane["wA:p1"].cwd, "/work/proj")
  T.eq(by_pane["wA:p1"].name, "review")
  T.eq(by_pane["wA:p1"].title, "review")
  T.eq(by_pane["wA:p1"].terminal_id, "term-1")
  T.eq(by_pane["wA:p1"].agent_session, session)
  T.eq(by_pane["wA:p2"].cwd, "/other/proj")
  T.eq(by_pane["wA:p3"].cwd, "/fallback")
end)

T.test("agents: same-kind same-basename targets remain distinguishable", function()
  local a = { kind = "pi", name = "review", status = "idle", cwd = "/one/proj", pane_id = "wA:p1", tab_id = "wA:t1" }
  local b = { kind = "pi", name = "code", status = "idle", cwd = "/two/proj", pane_id = "wA:p2", tab_id = "wA:t2" }
  T.eq(agents.display(a), "pi (review) · idle · /one/proj · wA:t1 · wA:p1")
  T.eq(agents.display(b), "pi (code) · idle · /two/proj · wA:t2 · wA:p2")
end)
