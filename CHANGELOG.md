# Changelog

## Unreleased

## 0.2.0

- **Levels that rise or fall**: two new measures, `rise` and `fall`, for a temperature, a tank or a battery. The
  value now is compared with the value when the window began (also one reported before it), so noise up and down
  does not add up; with several sensors the largest change counts, and the alarm names that sensor. Examples: a
  tank that falls more than 200 l in an hour, a temperature that falls 5 degrees in an hour (an open window) or
  rises 8 degrees in 30 minutes, a tank that is not filled up with at least 100 l in a day.
- `increase` is now called *Hur mycket en mätare ökat (vatten, el)* in the form, since a meter only counts up.

## 0.1.0

- First version. One rule per instance: what is counted (`count`, `distinct`, `increase`), the window (rolling or
  fixed times in local time, summer time included), the limit (at most or at least) and an alarm function of its own
  (`obj/limit/<group>/alarm`) that can be acknowledged.
- The sensors are chosen in the form and kept in step with the metadata on the functions both ways (`limit.group`,
  `limit.label`), last change wins.
- Modes from the Mode app, written as people see them. Events and the alarm survive a restart.
