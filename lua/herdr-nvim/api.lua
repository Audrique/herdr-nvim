-- Herdr 0.8.2's newline-delimited socket API. There is no draft/paste CLI;
-- pane.send_input wraps text in bracketed paste when the terminal enables it.
local M = {}
local sequence = 0

function M.request(method, params)
  local socket = vim.env.HERDR_SOCKET_PATH
  if not socket or socket == "" then
    return nil, "HERDR_SOCKET_PATH is missing; refusing to guess a draft destination"
  end
  sequence = sequence + 1
  local id = "herdr-nvim:" .. sequence
  local line, buffer = nil, ""
  local connected, channel = pcall(vim.fn.sockconnect, "pipe", socket, {
    rpc = false,
    on_data = function(_, data)
      buffer = buffer .. table.concat(data, "\n")
      line = line or buffer:match("^(.-)\n")
    end,
  })
  if not connected or channel == 0 then return nil, "cannot connect to Herdr API: " .. tostring(channel) end
  local sent, err = pcall(function()
    return vim.fn.chansend(channel, vim.json.encode({ id = id, method = method, params = params }) .. "\n")
  end)
  sent = sent and err > 0
  local answered = sent and vim.wait(2000, function() return line ~= nil end, 10)
  pcall(vim.fn.chanclose, channel)
  if not sent then return nil, "Herdr API write failed: " .. tostring(err) end
  if not answered then return nil, "Herdr API response timed out (delivery may have occurred; do not retry blindly)" end
  local ok, response = pcall(vim.json.decode, line)
  if not ok or type(response) ~= "table" or response.id ~= id then
    return nil, "invalid Herdr API response"
  end
  if type(response.error) == "table" then
    return nil, response.error.message or response.error.code or "Herdr API error"
  end
  if type(response.result) ~= "table" then return nil, "Herdr API response missing result" end
  return response.result
end

return M
