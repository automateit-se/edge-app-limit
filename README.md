# Limit guard - Gränsvakt (IoT Open edge app)

An IoT Open edge app that raises an alarm when something happened **too much** or **too little** within a time
window: more than 50 litres of water in an hour, three cars on the road in ten minutes, two different motion
sensors in the back yard within two minutes, a fridge compressor that has not run for two hours, more than two loud
noises between 23:00 and 06:00.

Technical names (metadata keys, topics) are in English; the settings form is in Swedish.

## One rule, four choices

| Choice | Setting | Options |
|---|---|---|
| What is counted | `measure` | `count` - the number of times a sensor becomes active, or goes above / below `threshold` (`event`)<br>`distinct` - the number of different sensors with such an event<br>`increase` - how much a meter reading went up (water, power; a meter that starts over counts from 0)<br>`rise` / `fall` - how much a level went up or down (a temperature, a tank, a battery): the value now against the value when the window began, the largest change among the sensors |
| The window | `window` | `rolling` - the last `window_min` minutes<br>`schedule` - fixed times `schedule_from`-`schedule_to` on `schedule_days`, local time (`timezone`, default Sweden) |
| The limit | `limit_kind`, `limit` | `at_most` - alarm as soon as the value goes above the limit<br>`at_least` - alarm when the window had less: a rolling window after one whole window since the first start, a scheduled window when it closes |
| The alarm | - | a function of the app's own, see below |

| Example | Counted | Window | Limit |
|---|---|---|---|
| Water | `increase` on the meter | rolling 60 min | at most 50 |
| Traffic | `count` of cars, `event_gap_s` 20 | rolling 10 min | at most 2 |
| Back yard | `distinct` motion sensors | rolling 2 min | at most 1 |
| Fridge compressor | `count`, power `above` 30 | rolling 120 min | at least 1 |
| Night noise | `count` of noises | 23:00-06:00 | at most 2 |
| Leaking tank | `fall` of the level | rolling 60 min | at most 200 |
| Open window | `fall` of the temperature | rolling 60 min | at most 5 |
| Stove, fire | `rise` of the temperature | rolling 30 min | at most 8 |
| Tank not filled | `rise` of the level | rolling 24 h | at least 100 |

A level is compared with its value when the window began, so noise up and down does not add up. "Too cold right
now" needs no change at all: count `below` a threshold instead.

## The alarm

The app creates one function of type `alarm` (name *<Namn> larm*, found again by `limit.app_id`):

- `obj/limit/<group>/alarm`: `1` = alarm, `0` = no alarm, retained; `msg` says what and which sensors, for example
  `too much: 3 (at most 2): Rörelse altan, Rörelse förråd`.
- `set/obj/limit/<group>/alarm` with `0` acknowledges it: it stays `0` until the rule has been kept and is broken
  again. `msg` says who (`acknowledged: Dashboard`).
- `obj/limit/<group>/value`: the current value, every 10 seconds (not retained).

The alarm function is an ordinary function: show it on the dashboard, use it in IoT Open's notifications, or choose
it in [För länge](https://github.com/automateit-se/edge-app-toolong) for sound, e-mail and SMS in steps (a step at
0 minutes notifies at once).

A scheduled *at least* window is only judged when the app watched it from its start, and its verdict stands until
the next window decides: a sign of activity in the next window clears the alarm at once.

## The form and the metadata

The sensors are chosen in the form (*Givare*) and stored as metadata on the functions: `limit.group` (the
instance's group, a comma separated list when several rules use the sensor) and `limit.label`. The two are kept in
step both ways and **whoever changed last wins**, as in För länge 0.4: a change in the form is written to the
functions, a change of the metadata in IoT Open or another system is written back into the form.

The form has two pages: *Regel* and *Avancerat* (`event_gap_s`, `timezone`, `group`, `active_value`, `mode_name`).

## Modes

With `active_modes` (for example `Borta, Semester`, written as in the
[Mode](https://github.com/automateit-se/edge-app-mode) app), the rule applies only in those modes. If the mode
function cannot be found, the rule always applies, with a warning.

## Restart and no internet

Events, meter readings, the alarm and the form the app last applied are kept retained on the local broker
(`obj/limit/<group>/state`, `/alarm`, `/form`), so a restart goes on where it was. Everything runs locally; the
edge client runs in UTC and the app works out local time itself, summer time included.

## Tests

```bash
lua5.3 tests/test_app.lua
```

The tests run `app.lua` in a simulated edge client with a simulated clock. All names, addresses and numbers in the
tests are made up.

## License

MIT
