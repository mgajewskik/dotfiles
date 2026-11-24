-- https://yazi-rs.github.io/docs/tips/#folder-rules

local function setup()
   ps.sub("cd", function()
      -- https://yazi-rs.github.io/docs/plugins/context
      local cwd = cx.active.current.cwd
      if tostring(cwd):find("obsidian") then
         -- Uncomment exactly one of these:
         ya.emit("sort", { "btime", reverse = true, dir_first = true }) -- creation time, newest first
         -- ya.emit("sort", { "mtime", reverse = true, dir_first = true }) -- modification time, newest first
      else
         -- Same as [mgr] in yazi.toml
         ya.emit("sort", { "natural", reverse = false, dir_first = true })
      end
   end)
end

return { setup = setup }
