# Writing a cogball prompt

A prompt is one cogball player policy. Every five seconds of match time its
container receives the private pitch view, sends your prompt and view to the
model, and returns one JSON directive for all three robots. External
policies use the same player decision wire. The game validates that directive
and executes it through its deterministic controller for the next five seconds.

Forty turns, one directive each. That is the whole game from your side.

## What your coach is told

The game selects one rules wording for both champions for the whole episode.
The default is canonical; `promptVariant` and `promptSeed` select a versioned
bank without changing either coach's private view or operator guidance. Your prompt is
appended under a **GUIDANCE FROM YOUR OPERATOR** heading, then the seat's view
of the pitch:

```json
{"turn": 7, "of": 40, "clock": {"played_s": 35.0, "left_s": 165.0},
 "score": {"you": 1, "them": 0},
 "you": {"alias": "Azure", "attacking_x": "+20", "defending_x": "-20"},
 "pitch": {"x_min": -20, "x_max": 20, "y_min": -12.5, "y_max": 12.5,
           "goal_half_width": 3.5, "your_penalty_area": "x <= -14, |y| <= 7",
           "walled": true},
 "ball": {"pos": [3.21, -1.04], "vel": [4.10, 0.62], "speed": 4.15,
          "possession": "AZ-2", "in_your_half": false, "on_boards": false},
 "your_robots": [{"id": "AZ-1", "pos": [-16.9, 0.4], "vel": [0.2, -0.1],
                  "facing": [1.0, 0.0], "speed": 0.22, "kick_ready": true,
                  "dist_to_ball": 20.1, "last_role": "keeper"}, "… 3 …"],
 "their_robots": [{"id": "CR-1", "pos": [7.7, 2.1], "vel": [-3.0, 0.4],
                   "facing": [-0.99, 0.13], "speed": 3.03,
                   "dist_to_ball": 5.6}, "… 3 …"],
 "last_turn": {"your_kicks": 2, "their_kicks": 1, "your_shots": 1,
               "their_shots": 0, "possession_pct_you": 63,
               "goals": [{"tick": 890, "by": "AZ-3", "for": "you"}]},
 "your_last_directive": "… what you played last turn, or null on turn 0 …"}
```

Everything is in **view coordinates**: metres from the centre spot. Your own
goal and the one you attack are named for you every turn, so a prompt never has
to remember which side it is on.

## The directive

Reply with a single JSON object (optionally wrapped in a standard outer
```` ```json ```` code fence) and nothing else:

```json
{"robots": [
   {"id": "AZ-1", "intent": "hold", "target": [-17.0, 0.4]},
   {"id": "AZ-2", "intent": "shoot"},
   {"id": "AZ-3", "intent": "pass", "pass_to": "AZ-2"}
 ]}
```

| field | requirement | legal values / default |
|---|---|---|
| `robots` | required | array of exactly your three robots (`AZ-1..3` or `CR-1..3`) |
| `id` | required | exact robot id for your seat (`AZ-1..3` for Azure, `CR-1..3` for Crimson) |
| `intent` | required | `"chase"`, `"intercept"`, `"hold"`, `"shoot"`, `"pass"`, `"clear"`, or `"press"` |
| `target` | required for `"hold"`; optional otherwise | `[x, y]` JSON array of two finite numbers in metres (`x ∈ [-20, 20]`, `y ∈ [-12.5, 12.5]`); omitted on non-`hold` intents applies no target bias |
| `pass_to` | required for `"pass"`; omit otherwise | teammate id ≠ self |
| `kick` | optional | `"auto"` (default) or `"never"` |
| `role` | optional | decorative label `"keeper"`, `"back"`, `"wing"` (default), or `"striker"` |
| `say` | optional | string, ≤ 48 runes (default `""`, truncated on rune boundary) |
| `note` | optional | string, ≤ 160 runes (default `""`, truncated on rune boundary) |

Parsing is strict on supplied values and never synthesizes fallback orders:
invalid JSON, prose outside the JSON object/fence, unknown enums,
missing/duplicate/wrong-team robot ids, out-of-bounds targets, `"hold"` without
`target`, or `"pass"` without a valid teammate `pass_to` are rejected
explicitly. Omitted optional fields take their fixed documented defaults above.
After one retry, a failed turn is recorded as a missed turn with zero actuator
input (no implicit fallback directive is synthesized). If an LLM seat completes
zero turns and loses every turn to provider/transport outage, the episode is
marked failed (`fault/host_error`) rather than an ordinary scored completion.

## What each intent actually does

The control layer is the same code for every policy, so two prompts are
strictly comparable.

| intent | the robot… |
|---|---|
| `chase` | drives at the ball |
| `intercept` | drives to where the ball will be (lead time from the closing speed) |
| `hold` | holds `target` and turns to face the ball once it arrives |
| `shoot` | lines up 0.9 m behind the ball on the goal side and strikes it |
| `pass` | the same, aimed at `pass_to`'s leading position |
| `clear` | the same, aimed away from your own goal toward a touchline |
| `press` | shadows the opponent nearest the ball |

`target` is used **directly** by `hold` and as a 20 % bias by everything else,
so it is a useful nudge even on `chase`. `kick: "never"` makes a robot shepherd
the ball instead of striking it — useful for a keeper you want between the ball
and the goal rather than swinging at it.

**The boards-escape rule overrides you.** When the ball hugs a wall outside the
goal-mouth corridor, the closest robot of your trio aims its kick back toward
the middle and kicks even if you said `never`; its two teammates are pushed
3 m off the boards so a whole trio cannot pile into one corner. The sim also
drops the ball on a neutral spot if it has not moved 1.5 m in 10 s. You cannot
turn either off, and you should not want to: a buried ball is a 0–0.

## What actually wins

Things that show up in the replays:

* **Never leave your goal empty.** One robot with `role: "keeper"` and
  `intent: "hold"` on the arc ~3 m in front of your line, with its `y` tracking
  about a third of the ball's `y`, is worth more than a third attacker.
* **Rotate by distance, not by name.** The nearest robot attacks; the deepest
  keeps. Re-assign the roles every turn from `dist_to_ball`.
* **Shoot from inside 12 m, pass from outside it.** A long shot is a free
  clearance for the other side; a pass to a robot already in space is not.
* **Use the whole 5 seconds.** A directive is a *plan*, not a twitch. Sending
  three robots at the ball wastes the turn — that is exactly what the `swarm`
  baseline does, and it loses.
* **Watch `on_boards`.** When it is true, send exactly one robot at the ball and
  keep the others in open space to collect the clearance.
* **Say something.** `note` and `say` appear in the broadcast feed. They cost
  nothing and they are how a spectator sees you playing.

## Fielding a policy

Reuse the shipped image and let the hosted model sidecar serve the prompt:

```bash
coworld upload-policy coworld-cogball:latest \
  --name my-cogball \
  --run /bin/cogball-player \
  --secret-env PLAYER_PROMPT="<your strategy>" \
  --use-llm --llm-model anthropic/claude-haiku-4.5
```

`PLAYER_SCRIPTED=formation` or `PLAYER_SCRIPTED=swarm` fields a built-in
baseline instead — the same directive shape, no LLM, microseconds per turn.

## Degrading

Every wait is bounded. Both seats' requests go out as **one parallel batch** per
turn with a 6.0 s deadline; anything that timed out, errored, or returned an
invalid directive is retried **once** as a single batch with a 2.5 s deadline,
all inside a 9.0 s monotonic per-turn cap. Player transport allowances remain
in milliseconds: 6000 for the first attempt and 2500 for repair, clipped to the
remaining 9000 ms absolute turn deadline. Two consecutive failures record a
`missed_turn` with zero actuator input for that seat (no fallback directive is
synthesized) and preserve the failed attempts' raw data. If the wall clock gets
close to the budget, a `budget_guard` record fires and remaining LLM turns are
skipped as missed turns so the episode ends `complete/full_time` rather than
`deadline`.
