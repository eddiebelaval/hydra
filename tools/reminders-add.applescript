-- reminders-add.applescript — add ONE reminder to a list, idempotently.
-- argv: listName, reminderName, body, year, month, day  (year=0 => no due date)
-- Dedupe by name across the whole list (completed or not): once it exists or is
-- ticked, we never re-add it. This keeps the projection churn-free.
on run argv
	set listName to item 1 of argv
	set theName to item 2 of argv
	set theBody to item 3 of argv
	set y to (item 4 of argv) as integer
	set m to (item 5 of argv) as integer
	set d to (item 6 of argv) as integer

	tell application "Reminders"
		if (count of (lists whose name is listName)) is 0 then
			make new list with properties {name:listName}
		end if
		tell (first list whose name is listName)
			if (count of (reminders whose name is theName)) is greater than 0 then
				return "SKIP"
			end if
			if y > 0 then
				set dd to (current date)
				set year of dd to y
				set month of dd to m
				set day of dd to d
				set hours of dd to 9
				set minutes of dd to 0
				set seconds of dd to 0
				make new reminder with properties {name:theName, body:theBody, due date:dd, remind me date:dd}
			else
				make new reminder with properties {name:theName, body:theBody}
			end if
			return "ADDED"
		end tell
	end tell
end run
