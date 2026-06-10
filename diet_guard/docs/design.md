I turned on pc today and diet guard did not work... pc got turned on at ~18:52 but the diet guard did not show, it should show immediately since there were no meals logged at
08:00 12:00 and 16:00 (since pc was turned off)

How it currently works:
It triggers every 5hr if no food was recorded as eaten

Issue:
It is semi-automatic, it assumes user will manually write down food so far, they will not
also 5hr is too much

What it should do:
Every 4hrs (STARTING at the "beginning of the day" so currently 8 AM) open a locker asking to fill what food was eaten, do it for every 4hrs (so next at 12:00 next at 16:00 next at 20:00) this has 2 benefits:

1. is fully automatic
2. makes user eat regularly which makes keeping diet easier

Initially user should write down name of the food, its FULL macro
(calories, protein, carbs and fats)
the diet_guard should hold this info in a "bank" of food info, so that next time this popup comes user
can

1. Write down the food manually again
2. The input should suggest what food do they want to write down (think autocomplete)
3. User should be also able to expand list of food and choose from this list, as user writes down in
   input this list should be filtered to match whatever used wrote down (some smart filtering, not
   literally "if the food begins with this name" user can make typos, write something similar but
   not exactly the same and so on) -> this should be a LOCAL database but we should use
   open food data (or whatever we are using right now) to help us fill it but the search should
   only use historical data of what the user filled in before

This every 4hrs process should also inform user how many calories they have left out of total calories
for the day

This is for Friday-Monday INCLUDING, for Tuesday, Wednesday, Thursday it should work a bit different
assume that user comebacks late (say 5PM or later)
LOCK the screen so user fills out full food intake for this day so far, make this a requiremetn to
access the PC
after that work as before so show diet lock at specific hour (lets say they come at
5PM so probably at 8PM)
Ok in fact I think we should not have 2 different processes, make it a one process that accumulates
"food times"
so lets say user turn on pc before 8AM show nothing and at 8AM show something
if user turns on pc after 8AM but before 12:00 show only this one 8AM food time
if user turns on lets say 17:00 make them fill data for 8AM, 12:00 and 16:00..
and so on

Another feature would be allowing for complicated "meal" type items, so for example I would like to log that at 12:00 I ate a soup and a meal
soup with specific macro
and dinner which consisted of
salad
chicken
rice
each having their own macro that I would want to fill for all of them separately and make the program
calculate the sum of it, both the individual items and the meal itself should be saved to database
