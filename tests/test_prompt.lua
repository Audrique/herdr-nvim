local prompt = require("herdr-nvim.prompt")

T.test("prompt: single comment, no git context", function()
  local s = prompt.format({
    { comment = { file = "/tmp/x.py", start_line = 5, end_line = 5, text = "rename to double" },
      snippet = { "def f(x): return x*2" } },
  }, {})
  local expected = table.concat({
    "Code review comments from my editor:",
    "",
    "1. /tmp/x.py:5",
    "   > def f(x): return x*2",
    "   Comment: rename to double",
    "",
    "Please address each comment. Reply with what you changed per item.",
  }, "\n")
  T.eq(s, expected)
end)

T.test("prompt: multiple comments numbered, snippet capped at 3 lines, header context", function()
  local s = prompt.format({
    { comment = { file = "a.rs", start_line = 1, end_line = 9, text = "c1" },
      snippet = { "l1", "l2", "l3", "l4", "l5" } },
    { comment = { file = "b.rs", start_line = 2, end_line = 3, text = "c2" },
      snippet = { "x", "y" } },
  }, { header_context = "repo: demo, branch: main" })
  T.ok(s:find("Code review comments from my editor (repo: demo, branch: main):", 1, true) == 1)
  T.ok(s:find("1. a.rs:1-9", 1, true))
  T.ok(s:find("   > l3", 1, true))
  T.ok(not s:find("> l4", 1, true), "snippet must cap at 3 lines")
  T.ok(s:find("2. b.rs:2-3", 1, true))
  T.ok(s:find("   Comment: c2", 1, true))
end)

T.test("prompt: comments use the same short location as references", function()
  local s = prompt.format({
    { comment = { file = "/repo/lua/init.lua", start_line = 42, end_line = 42, text = "c" }, snippet = {} },
    { comment = { file = "/elsewhere/x.lua", start_line = 1, end_line = 3, text = "d" }, snippet = {} },
  }, { cwd = "/repo" })
  T.ok(s:find("1. lua/init.lua:42\n", 1, true))
  T.ok(s:find("2. /elsewhere/x.lua:1-3\n", 1, true))
end)

T.test("prompt: format_ref is a bare citation ending in a space", function()
  local s = prompt.format_ref({ file = "/repo/lua/init.lua", start_line = 5, end_line = 10 }, { cwd = "/repo" })
  T.eq(s, "lua/init.lua:5-10 ")
end)

T.test("prompt: format_ref collapses a single line", function()
  T.eq(prompt.format_ref({ file = "/repo/a.rs", start_line = 7, end_line = 7 }, { cwd = "/repo" }), "a.rs:7 ")
end)

T.test("prompt: tabbed code excerpts render spaces with one explicit display-only note", function()
  local items = {
    { comment = { file = "a.lua", start_line = 1, end_line = 2, text = "review indentation" },
      snippet = { "\tlocal x = true", "\t\treturn x\t-- comment" } },
    { comment = { file = "b.lua", start_line = 1, end_line = 1, text = "another" },
      snippet = { "\treturn false" } },
  }
  local original = vim.deepcopy(items)
  local s = prompt.format(items)
  T.ok(not s:find("\t", 1, true), "rendered snippets must not contain draft-breaking tabs")
  T.ok(s:find("   >     local x = true", 1, true))
  T.ok(s:find("   >         return x    -- comment", 1, true))
  local note = "Note: snippet tabs shown as 4 spaces (display only); saved files remain authoritative."
  T.ok(s:find("Code review comments from my editor:\n" .. note .. "\n\n", 1, true) == 1)
  local _, count = s:gsub("Note:", "")
  T.eq(count, 1, "normalization note appears once per payload")
  T.eq(items, original, "input snippets and comments must remain unchanged")
end)

T.test("prompt: tabs in undisplayed excerpt lines do not produce a normalization note", function()
  local s = prompt.format({
    { comment = { file = "a.lua", start_line = 1, end_line = 4, text = "review" },
      snippet = { "one", "two", "three", "\tfour" } },
  })
  T.ok(not s:find("Note:", 1, true))
  T.ok(not s:find("four", 1, true))
end)

T.test("prompt: tab rendering does not modify the source buffer or authoritative saved file", function()
  local comments = require("herdr-nvim.comments")
  local file = vim.fn.tempname() .. ".lua"
  local saved = { "\tlocal saved = true" }
  vim.fn.writefile(saved, file)
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(b, file)
  local source = { "\tlocal unsaved = true", "\treturn unsaved" }
  vim.api.nvim_buf_set_lines(b, 0, -1, false, source)
  local id = comments.add(b, 1, 2, "review")
  local snippet = comments.snippet(id)
  local tick, modified = vim.api.nvim_buf_get_changedtick(b), vim.bo[b].modified
  local s = prompt.format({ { comment = comments.get(id), snippet = snippet } })
  local actual_source = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local actual_tick, actual_modified = vim.api.nvim_buf_get_changedtick(b), vim.bo[b].modified
  local actual_saved = vim.fn.readfile(file)
  comments.delete(id)
  vim.api.nvim_buf_delete(b, { force = true })
  vim.fn.delete(file)
  T.ok(s:find("   >     local unsaved = true", 1, true))
  T.eq(snippet, source, "original snippet table must remain unchanged")
  T.eq(actual_source, source)
  T.eq(actual_tick, tick, "formatting must not edit the buffer")
  T.eq(actual_modified, modified, "formatting must preserve buffer modified state")
  T.eq(actual_saved, saved, "formatting must not write the saved file")
end)

T.test("prompt: user comment and path tabs stay literal and are refused actionably", function()
  local dispatch = require("herdr-nvim.dispatch")
  local function no_io() error("tab rejection must occur before I/O") end
  for _, c in ipairs({
    { file = "/repo/a.lua", start_line = 1, end_line = 1, text = "literal\tcomment" },
    { file = "/repo/a\tb.lua", start_line = 1, end_line = 1, text = "comment" },
  }) do
    local s = prompt.format({ { comment = c, snippet = { "normal code" } } }, { cwd = "/repo" })
    T.ok(s:find("\t", 1, true), "only snippet tabs may be normalized")
    T.ok(not s:find("Note:", 1, true))
    local ok, err = dispatch.send("wA:p1", s, {}, no_io, no_io)
    T.eq(ok, false)
    T.ok(err:find("replace tabs with spaces", 1, true))
  end
  local ref = prompt.format_ref({ file = "/repo/a\tb.lua", start_line = 1, end_line = 1 }, { cwd = "/repo" })
  T.eq(ref, "a\tb.lua:1 ")
  local ok, err = dispatch.send("wA:p1", ref, {}, no_io, no_io)
  T.eq(ok, false)
  T.ok(err:find("replace tabs with spaces", 1, true))
end)

T.test("prompt: _relpath shortens against the cwd, keeps outside paths absolute", function()
  T.eq(prompt._relpath("/repo/lua/init.lua", "/repo"), "lua/init.lua")
  T.eq(prompt._relpath("/repo/lua/init.lua", "/repo/"), "lua/init.lua", "trailing slash tolerated")
  T.eq(prompt._relpath("/elsewhere/x.lua", "/repo"), "/elsewhere/x.lua", "outside the cwd stays absolute")
  T.eq(prompt._relpath("/repo-other/x.lua", "/repo"), "/repo-other/x.lua", "prefix must end at a separator")
  T.eq(prompt._relpath("/repo/x.lua", ""), "/repo/x.lua", "no cwd known → unchanged")
end)
