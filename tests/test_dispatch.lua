local dispatch = require("herdr-nvim.dispatch")

local identity = {
  pane_id = "wA:p1", terminal_id = "terminal-1", workspace_id = "wA", tab_id = "wA:t1",
  agent = "pi", agent_status = "idle", cwd = "/shell", foreground_cwd = "/repo",
  agent_session = { agent = "pi", kind = "path", value = "/session.jsonl" },
}

local function recorder(changes, fail_method)
  local calls, commands = {}, {}
  local agent, pane = vim.deepcopy(identity), vim.deepcopy(identity)
  changes = changes or {}
  for k, v in pairs(changes.agent or {}) do agent[k] = v end
  for k, v in pairs(changes.pane or {}) do pane[k] = v end
  local function request(method, params)
    table.insert(calls, { method, params })
    if method == fail_method then return nil, "boom" end
    if method == "agent.get" then return { agent = agent } end
    if method == "pane.get" then return { pane = pane } end
    return { type = "ok" }
  end
  local function exec(argv)
    table.insert(commands, argv)
    return { code = fail_method == "prompt" and 1 or 0, stderr = "boom" }
  end
  return calls, commands, exec, request
end

T.test("dispatch: draft uses paste transport with empty keys, no Enter or shell", function()
  local calls, commands, exec, request = recorder()
  local text = "line1\nline2  '\"$(touch /tmp/not-executed)"
  T.ok(dispatch.send("wA:p1", text, { submit = false, agent = identity }, exec, request))
  T.eq(#commands, 0)
  T.eq(calls, {
    { "agent.get", { target = "wA:p1" } },
    { "pane.get", { pane_id = "wA:p1" } },
    { "pane.send_input", { pane_id = "wA:p1", text = text, keys = {} } },
  })
  T.ok(vim.json.encode(calls[3][2]):find('"keys":[]', 1, true))
end)

T.test("dispatch: normalized picker identity compares foreground cwd, not shell cwd", function()
  local _, _, exec, request = recorder()
  local selected = vim.deepcopy(identity)
  selected.kind, selected.agent = selected.agent, nil
  selected.cwd, selected.foreground_cwd = selected.foreground_cwd, nil
  T.ok(dispatch.send("wA:p1", "hi", { agent = selected }, exec, request))
end)

T.test("dispatch: explicit submit retains agent prompt API", function()
  local _, commands, exec, request = recorder()
  T.ok(dispatch.send("wA:p1", "hi", { submit = true }, exec, request))
  T.eq(commands, { { "herdr", "agent", "prompt", "wA:p1", "hi" } })
end)

T.test("dispatch: explicit submit failure returns error", function()
  local _, commands, exec, request = recorder(nil, "prompt")
  local ok, err = dispatch.send("wA:p1", "hi", { submit = true }, exec, request)
  T.eq(ok, false)
  T.ok(err:find("boom"))
  T.eq(#commands, 1)
end)

T.test("dispatch: paste failure does not fall back to raw text or Enter", function()
  local calls, commands, exec, request = recorder(nil, "pane.send_input")
  local ok, err = dispatch.send("wA:p1", "hi", {}, exec, request)
  T.eq(ok, false)
  T.ok(err:find("boom"))
  T.eq(#calls, 3)
  T.eq(#commands, 0)
end)

T.test("dispatch: unsafe controls and bracket-paste escapes are refused before I/O", function()
  for _, text in ipairs({ "x\0", "x\r", "x\3", "x\8", "x\127", "x\27[201~", "x\27[200~", "x\194\133", "" }) do
    local calls, commands, exec, request = recorder()
    local ok = dispatch.send("wA:p1", text, {}, exec, request)
    T.eq(ok, false, vim.inspect(text))
    T.eq(#calls, 0)
    T.eq(#commands, 0)
  end
end)

T.test("dispatch: tabs are refused with an actionable error, not silently mutated", function()
  local calls, commands, exec, request = recorder()
  local ok, err = dispatch.send("wA:p1", "code\tindent", {}, exec, request)
  T.eq(ok, false)
  T.ok(err:find("replace tabs with spaces", 1, true))
  T.eq(#calls, 0)
  T.eq(#commands, 0)
end)

T.test("dispatch: blocked/unknown and pending launch targets are refused", function()
  for _, changes in ipairs({
    { agent_status = "blocked" }, { agent_status = "unknown" }, { agent_status = "new-state" }, { launch_pending = true },
  }) do
    local calls, commands, exec, request = recorder({ agent = changes })
    T.eq(dispatch.send("wA:p1", "hi", {}, exec, request), false)
    T.eq(#calls, 1)
    T.eq(#commands, 0)
  end
end)

T.test("dispatch: working and unseen idle completion are acceptable draft states", function()
  for _, status in ipairs({ "working", "done" }) do
    local _, _, exec, request = recorder({ agent = { agent_status = status }, pane = { agent_status = status } })
    T.ok(dispatch.send("wA:p1", "hi", {}, exec, request))
  end
end)

T.test("dispatch: selected terminal, session, kind and location are revalidated", function()
  for _, changes in ipairs({
    { terminal_id = "replacement" }, { agent = "claude" }, { tab_id = "wA:t2" },
    { workspace_id = "wB" }, { pane_id = "wA:p2" }, { foreground_cwd = "/other-repo" },
    { agent_session = { agent = "pi", kind = "path", value = "/new-session.jsonl" } },
  }) do
    local calls, commands, exec, request = recorder({ agent = changes })
    T.eq(dispatch.send("wA:p1", "hi", { agent = identity }, exec, request), false)
    T.eq(#calls, 1)
    T.eq(#commands, 0)
  end
end)

T.test("dispatch: pane replacement/dialog between selection and paste is refused", function()
  for _, changes in ipairs({ { terminal_id = "replacement" }, { agent_status = "blocked" }, { agent_status = "unknown" } }) do
    local calls, commands, exec, request = recorder({ pane = changes })
    T.eq(dispatch.send("wA:p1", "hi", { agent = identity }, exec, request), false)
    T.eq(#calls, 2)
    T.eq(#commands, 0)
  end
end)

T.test("dispatch: unavailable identity fails closed", function()
  local calls, commands, exec, request = recorder(nil, "agent.get")
  T.eq(dispatch.send("wA:p1", "hi", {}, exec, request), false)
  T.eq(#calls, 1)
  T.eq(#commands, 0)
end)

T.test("dispatch: invalid paste acknowledgement fails closed", function()
  local _, _, exec, request = recorder()
  local ok = dispatch.send("wA:p1", "hi", {}, exec, function(method, params)
    if method == "pane.send_input" then return { type = "unexpected" } end
    return request(method, params)
  end)
  T.eq(ok, false)
end)

T.test("dispatch: missing socket fails closed, never guesses default session", function()
  local api = require("herdr-nvim.api")
  local previous = vim.env.HERDR_SOCKET_PATH
  vim.env.HERDR_SOCKET_PATH = nil
  local result, err = api.request("pane.send_input", { pane_id = "wA:p1", text = "hi", keys = {} })
  vim.env.HERDR_SOCKET_PATH = previous
  T.eq(result, nil)
  T.ok(err:find("HERDR_SOCKET_PATH", 1, true))
end)

T.test("dispatch: real isolated socket preserves multiline text and empty key array", function()
  local uv = vim.uv
  local socket = vim.fn.tempname()
  local previous = vim.env.HERDR_SOCKET_PATH
  local server, clients, received = uv.new_pipe(false), {}, {}
  server:bind(socket)
  server:listen(8, function(err)
    assert(not err, err)
    local client, buffer = uv.new_pipe(false), ""
    table.insert(clients, client)
    server:accept(client)
    client:read_start(function(read_err, data)
      assert(not read_err, read_err)
      if not data then return end
      buffer = buffer .. data
      local line = buffer:match("^(.-)\n")
      if not line then return end
      client:read_stop()
      local request = vim.json.decode(line)
      table.insert(received, request)
      local result = { type = "ok" }
      if request.method == "agent.get" then result = { agent = identity } end
      if request.method == "pane.get" then result = { pane = identity } end
      local response = vim.json.encode({ id = request.id, result = result }) .. "\n"
      -- Deliberately fragmented response exercises newline framing.
      client:write(response:sub(1, 9))
      client:write(response:sub(10))
    end)
  end)
  vim.env.HERDR_SOCKET_PATH = socket
  local text = "first\nsecond  '\"$()`"
  local success, result = pcall(dispatch.send, "wA:p1", text, { agent = identity }, function() error("no shell") end)
  vim.env.HERDR_SOCKET_PATH = previous
  for _, client in ipairs(clients) do if not client:is_closing() then client:close() end end
  server:close()
  uv.fs_unlink(socket)
  T.ok(success, result)
  T.ok(result)
  T.eq(#received, 3)
  T.eq(received[3].method, "pane.send_input")
  T.eq(received[3].params.text, text)
  T.eq(received[3].params.keys, {})
end)
