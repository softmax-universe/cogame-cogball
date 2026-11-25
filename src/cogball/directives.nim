## Directives: the coaching object a seat plays for one 120-tick turn, its
## strict canonical parser, and the view-coordinate transform every policy
## sees the world through.
##
## Two hard rules live here and are pinned by tests/test_directives.nim:
##
## 1. **Every recorded string is truncated on RUNE boundaries, never bytes.**
##    A byte-truncated multi-byte character is exactly the bug that makes
##    replay bytes render in a browser but fail a strict parser.
## 2. **Parsing is strict and never synthesizes fallback orders.** Replies must
##    provide the canonical JSON shape with exact robot IDs for all three of the
##    seat's robots, valid intents, a `[x, y]` target when `intent` is `"hold"`,
##    and a valid teammate `pass_to` when `intent` is `"pass"`. Optional fields
##    (`kick`, `role`, non-hold `target`, `note`, `say`) use fixed documented
##    defaults when omitted, and supplied invalid values are rejected explicitly.

import
  std/[json, math, unicode],
  sim

# --------------------------------------------------------------------------
# View coordinates: metres from the centre spot. The ONLY coordinates a policy
# ever sees or sends.
# --------------------------------------------------------------------------

const
  ViewHalfW* = 20.0
  ViewHalfH* = 12.5
  GoalHalfWidth* = 3.5

proc viewX*(x: int32): float {.inline.} =
  float(int(x) - int(CentreX)) / 1_000_000.0

proc viewY*(y: int32): float {.inline.} =
  float(int(y) - int(CentreY)) / 1_000_000.0

proc worldXOfView*(v: float): int32 {.inline.} =
  int32(int(CentreX) + int(round(clamp(v, -ViewHalfW, ViewHalfW) * 1_000_000.0)))

proc worldYOfView*(v: float): int32 {.inline.} =
  int32(int(CentreY) + int(round(clamp(v, -ViewHalfH, ViewHalfH) * 1_000_000.0)))

proc round2*(value: float): float {.inline.} =
  ## Two decimals, the precision every number in the seat view carries.
  round(value * 100.0) / 100.0

# --------------------------------------------------------------------------
# Rune-boundary truncation
# --------------------------------------------------------------------------

proc clipRunes*(text: string, maxRunes: int): string =
  ## Truncates on a RUNE boundary (babel's `cleanNotes`, ported). Slicing a
  ## `string` by byte index on any path to the replay is forbidden.
  result = text.strip()
  var clean = newStringOfCap(result.len)
  for rune in result.runes:
    # Control characters would corrupt a replay chat record and a JSON line.
    if int32(rune) >= 32 or int32(rune) == 9:
      clean.add($rune)
  result = clean
  if maxRunes <= 0:
    return ""
  if result.runeLen <= maxRunes:
    return
  result = result.runeSubStr(0, maxRunes - 1) & "\u2026"

# --------------------------------------------------------------------------
# Robot ids
# --------------------------------------------------------------------------

proc robotIndexOfId*(id: string): int =
  ## Exact canonical robot ID: `AZ-1`..`AZ-3` or `CR-1`..`CR-3`.
  ## Returns -1 for any other string.
  case id
  of "AZ-1": 0
  of "AZ-2": 1
  of "AZ-3": 2
  of "CR-1": 3
  of "CR-2": 4
  of "CR-3": 5
  else: -1

# --------------------------------------------------------------------------
# Strict enum parsing
# --------------------------------------------------------------------------

proc parseRole(text: string, role: var Role): bool =
  case text
  of "keeper": role = roleKeeper; true
  of "back": role = roleBack; true
  of "wing": role = roleWing; true
  of "striker": role = roleStriker; true
  else: false

proc parseIntent(text: string, intent: var Intent): bool =
  case text
  of "chase": intent = inChase; true
  of "intercept": intent = inIntercept; true
  of "hold": intent = inHold; true
  of "shoot": intent = inShoot; true
  of "pass": intent = inPass; true
  of "clear": intent = inClear; true
  of "press": intent = inPress; true
  else: false

proc parseKick(text: string, kick: var KickMode): bool =
  case text
  of "auto": kick = kickAuto; true
  of "never": kick = kickNever; true
  else: false

# --------------------------------------------------------------------------
# Directive construction and serialization
# --------------------------------------------------------------------------

proc emptyDirective*(seat: Seat): Directive =
  result.source = dsScripted
  for slot in 0 ..< RobotsPerSeat:
    result.robots[slot] = RobotOrder(
      role: roleWing, intent: inChase,
      targetX: CentreX, targetY: CentreY,
      passTo: -1, kick: kickAuto, say: "")
  discard seat

proc robotOrderJson(
  seat: Seat,
  slot: int,
  order: RobotOrder,
  rounded: bool
): JsonNode =
  result = %*{
    "id": robotId(firstRobotOf(seat) + slot),
    "intent": intentText(order.intent)
  }
  if order.targetX != NoTarget and order.targetY != NoTarget:
    result["target"] =
      if rounded: %*[round2(viewX(order.targetX)), round2(viewY(order.targetY))]
      else: %*[viewX(order.targetX), viewY(order.targetY)]
  if order.intent == inPass and order.passTo >= 0:
    result["pass_to"] = %robotId(int(order.passTo))
  if order.kick != kickAuto:
    result["kick"] = %kickText(order.kick)
  if order.role != roleWing:
    result["role"] = %roleText(order.role)
  if order.say.len > 0:
    result["say"] = %order.say

proc directiveJson*(sim: SimServer, seat: Seat, directive: Directive): JsonNode =
  ## The `directive` replay chat record. Capped at MaxDirectiveRecordRunes by
  ## the caller (`recordRunes` below). Omits unused optionals rather than
  ## emitting null placeholders.
  discard sim
  var robots = newJArray()
  for slot in 0 ..< RobotsPerSeat:
    robots.add(robotOrderJson(seat, slot, directive.robots[slot], rounded = true))
  result = %*{
    "k": "directive",
    "turn": directive.turn,
    "seat": ord(seat),
    "alias": seatAlias(seat),
    "source": sourceText(directive.source),
    "latency_ms": directive.latencyMs,
    "robots": robots
  }
  if directive.note.len > 0:
    result["note"] = %directive.note

proc actionJson*(sim: SimServer, seat: Seat, directive: Directive): JsonNode =
  ## Exact installed control directive; spectator records round positions for display.
  ## Omits unused optionals rather than emitting null placeholders.
  discard sim
  var robots = newJArray()
  for slot in 0 ..< RobotsPerSeat:
    robots.add(robotOrderJson(seat, slot, directive.robots[slot], rounded = false))
  result = %*{"robots": robots}
  if directive.note.len > 0:
    result["note"] = %directive.note

proc clipJsonStrings(node: JsonNode, budget: int): JsonNode =
  ## A copy of `node` with every STRING VALUE clipped to `budget` runes. Keys
  ## are untouched, so the shape a reader matches on survives.
  case node.kind
  of JString:
    result = %clipRunes(node.getStr(), budget)
  of JArray:
    result = newJArray()
    for item in node:
      result.add(clipJsonStrings(item, budget))
  of JObject:
    result = newJObject()
    for key, value in node:
      result[key] = clipJsonStrings(value, budget)
  else:
    result = node

proc capRecord*(text: string): string =
  ## Every replay chat record is capped at MaxDirectiveRecordRunes runes, on a
  ## rune boundary. ctf's 10-character shout cap is deliberately raised here.
  ##
  ## The cap is on the SERIALIZED record, and JSON escaping is what makes that
  ## non-obvious: a `"` or a `\` inside a note or a say costs two runes on the
  ## wire, so a directive whose note and three says are all legal at their own
  ## caps (160 + 3x48 runes) serializes to 1053 runes when every one of those
  ## characters escapes. Blindly clipping the serialized text at 900 would then
  ## cut the object mid-key: still valid UTF-8 on a rune boundary, but no
  ## longer JSON. `broadcast.applyRecord` would silently drop the feed line and
  ## `tools/replay_summary.py` would skip the record, so phase 60 would
  ## under-count exactly the LLM directives it is there to verify.
  ##
  ## So an over-long record is shrunk STRUCTURALLY: parse it, clip its string
  ## values to a halving budget until the serialization fits, and only fall
  ## back to the blind rune clip when the text is not a JSON object at all.
  ## The result is always parseable, and a record already inside the cap is
  ## returned byte for byte.
  if text.runeLen <= MaxDirectiveRecordRunes:
    return clipRunes(text, MaxDirectiveRecordRunes)
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return clipRunes(text, MaxDirectiveRecordRunes)
  if node.kind != JObject:
    return clipRunes(text, MaxDirectiveRecordRunes)
  var budget = MaxNoteRunes
  while budget > 0:
    budget = budget div 2
    let shrunk = $clipJsonStrings(node, budget)
    if shrunk.runeLen <= MaxDirectiveRecordRunes:
      return shrunk
  clipRunes(text, MaxDirectiveRecordRunes)

# --------------------------------------------------------------------------
# The strict canonical parser
# --------------------------------------------------------------------------

proc finiteNumberOf(node: JsonNode, ok: var bool): float =
  ## Accepts a finite JSON number only (int or float); rejects strings and
  ## non-finite values.
  ok = false
  if node.isNil:
    return 0.0
  case node.kind
  of JInt:
    ok = true
    return float(node.getInt())
  of JFloat:
    let value = node.getFloat()
    if value != value or value == Inf or value == NegInf:
      return 0.0
    ok = true
    return value
  else:
    return 0.0

proc rejectDirective(reason: string): tuple[directive: Directive, usable: bool, reason: string] =
  (Directive(), false, reason)

proc parseDirective*(
  sim: SimServer,
  seat: Seat,
  payload: JsonNode,
  turn: int
): tuple[directive: Directive, usable: bool, reason: string] =
  ## Strictly validates one JSON directive payload for `seat`. Never synthesizes
  ## missing robots, unknown enums, bad targets, or fallback orders.
  discard sim
  if payload.isNil or payload.kind != JObject:
    return rejectDirective("directive must be a JSON object")
  var directive = Directive(turn: int32(turn), source: dsLlm)
  if payload.hasKey("note"):
    if payload["note"].kind != JString:
      return rejectDirective("note must be a string")
    directive.note = clipRunes(payload["note"].getStr(), MaxNoteRunes)

  if not payload.hasKey("robots") or payload["robots"].kind != JArray:
    return rejectDirective("robots must be an array of 3 robot orders")
  let robotsNode = payload["robots"]
  if robotsNode.len != RobotsPerSeat:
    return rejectDirective("robots must contain exactly 3 entries, got " & $robotsNode.len)

  let base = firstRobotOf(seat)
  var filled: array[RobotsPerSeat, bool]
  for entry in robotsNode:
    if entry.kind != JObject:
      return rejectDirective("each robot entry must be a JSON object")
    if not entry.hasKey("id") or entry["id"].kind != JString:
      return rejectDirective("robot entry requires a string id")
    let rawId = entry["id"].getStr()
    let index = robotIndexOfId(rawId)
    if index < 0 or seatOfRobot(index) != seat:
      return rejectDirective("invalid robot id for " & seatAlias(seat) & ": " & rawId)
    let slot = index - base
    if filled[slot]:
      return rejectDirective("duplicate robot id: " & rawId)
    filled[slot] = true

    var order = RobotOrder(
      role: roleWing,
      targetX: NoTarget,
      targetY: NoTarget,
      passTo: -1'i32,
      kick: kickAuto
    )
    if not entry.hasKey("intent") or entry["intent"].kind != JString or
        not parseIntent(entry["intent"].getStr(), order.intent):
      return rejectDirective("invalid intent for " & rawId)
    if entry.hasKey("role"):
      if entry["role"].kind != JString or
          not parseRole(entry["role"].getStr(), order.role):
        return rejectDirective("invalid role for " & rawId)
    if entry.hasKey("kick"):
      if entry["kick"].kind != JString or
          not parseKick(entry["kick"].getStr(), order.kick):
        return rejectDirective("invalid kick for " & rawId)

    if entry.hasKey("target"):
      if entry["target"].kind != JArray or entry["target"].len != 2:
        return rejectDirective("target for " & rawId & " must be a [x, y] array")
      var okX = false
      var okY = false
      let vx = finiteNumberOf(entry["target"][0], okX)
      let vy = finiteNumberOf(entry["target"][1], okY)
      if not okX or not okY:
        return rejectDirective("target coordinates for " & rawId & " must be finite numbers")
      if vx < -ViewHalfW or vx > ViewHalfW or vy < -ViewHalfH or vy > ViewHalfH:
        return rejectDirective("target coordinates for " & rawId & " out of pitch bounds")
      order.targetX = worldXOfView(vx)
      order.targetY = worldYOfView(vy)
    elif order.intent == inHold:
      return rejectDirective("hold intent for " & rawId & " requires a [x, y] target")

    if entry.hasKey("pass_to") and entry["pass_to"].kind != JNull:
      if entry["pass_to"].kind != JString:
        return rejectDirective("pass_to for " & rawId & " must be a teammate id")
      let passId = entry["pass_to"].getStr()
      let mate = robotIndexOfId(passId)
      if mate < 0 or mate == index or seatOfRobot(mate) != seat:
        return rejectDirective("invalid pass_to for " & rawId & ": " & passId)
      order.passTo = int32(mate)
    if order.intent == inPass and order.passTo < 0:
      return rejectDirective("pass intent for " & rawId & " requires a valid teammate pass_to")

    if entry.hasKey("say"):
      if entry["say"].kind != JString:
        return rejectDirective("say for " & rawId & " must be a string")
      order.say = clipRunes(entry["say"].getStr(), MaxSayRunes)

    directive.robots[slot] = order

  for slot in 0 ..< RobotsPerSeat:
    if not filled[slot]:
      return rejectDirective("missing robot order for " & robotId(base + slot))
  (directive, true, "")
