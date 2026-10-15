--- @sync entry

-- Esc cancels whatever is active (find, filter, search, visual mode, selection); with nothing to cancel, it quits.
local function entry()
   local tab = cx.active
   local has_something_to_cancel = tab.finder
      or tab.current.files.filter
      or tab.current.cwd.spec.is_search
      or not tab.mode.is_normal
      or #tab.selected > 0

   if has_something_to_cancel then
      ya.emit("escape", {})
   else
      ya.emit("quit", {})
   end
end

return { entry = entry }
