# Changelog

## Unreleased

## 0.1.0

- First version. One rule per instance: what is counted (`count`, `distinct`, `increase`), the window (rolling or
  fixed times in local time, summer time included), the limit (at most or at least) and an alarm function of its own
  (`obj/limit/<group>/alarm`) that can be acknowledged.
- The sensors are chosen in the form and kept in step with the metadata on the functions both ways (`limit.group`,
  `limit.label`), last change wins.
- Modes from the Mode app, written as people see them. Events and the alarm survive a restart.
