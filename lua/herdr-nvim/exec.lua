local M = {}

function M.default_exec(argv)
  local ok, r = pcall(function() return vim.system(argv, { text = true }):wait() end)
  if not ok then return { code = 1, stdout = "", stderr = tostring(r) } end
  return { code = r.code, stdout = r.stdout or "", stderr = r.stderr or "" }
end

return M
