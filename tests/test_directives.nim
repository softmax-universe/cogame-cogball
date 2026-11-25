## Strict canonical directive parsing, outer Markdown JSON fence support,
## and the rune-boundary truncation rule.
##
## A byte-truncated multi-byte character is exactly the bug that makes replay
## bytes render in a browser but fail a strict parser, so the emoji case here
## is not decoration: it is the assertion the whole rune discipline exists for.

import std/[json, strutils, unicode]
import lib/helpers
import cogball/[broadcast, llm]

proc parseOf(
  sim: SimServer,
  seat: Seat,
  text: string
): tuple[directive: Directive, usable: bool, reason: string] =
  let payload = extractJsonObject(text)
  parseDirective(sim, seat, payload, 1)

proc validCanonicalAndFenced() =
  var sim = playing(testConfig())
  let minimal = """{"robots":[
 {"id":"AZ-1","intent":"hold","target":[-17,0]},
 {"id":"AZ-2","intent":"shoot"},
 {"id":"AZ-3","intent":"pass","pass_to":"AZ-2"}]}"""
  for variant in [minimal, "```json\n" & minimal & "\n```", "```\n" & minimal & "\n```"]:
    let got = sim.parseOf(Azure, variant)
    doAssert got.usable, got.reason
    doAssert got.directive.note == ""
    doAssert got.directive.robots[0].intent == inHold
    doAssert got.directive.robots[0].role == roleWing
    doAssert got.directive.robots[0].kick == kickAuto
    doAssert got.directive.robots[0].targetX == worldXOfView(-17.0)
    doAssert got.directive.robots[1].intent == inShoot
    doAssert got.directive.robots[1].targetX == NoTarget
    doAssert got.directive.robots[1].targetY == NoTarget
    doAssert got.directive.robots[2].intent == inPass
    doAssert got.directive.robots[2].passTo == 1
    let serialized = actionJson(sim, Azure, got.directive)
    doAssert not serialized.hasKey("note")
    doAssert not serialized["robots"][0].hasKey("pass_to")
    doAssert not serialized["robots"][0].hasKey("kick")
    doAssert not serialized["robots"][0].hasKey("role")
    doAssert not serialized["robots"][0].hasKey("say")
    doAssert serialized["robots"][0].hasKey("target")
    doAssert not serialized["robots"][1].hasKey("target")
    doAssert not serialized["robots"][1].hasKey("pass_to")
    doAssert serialized["robots"][2]["pass_to"].getStr() == "AZ-2"
    let record = directiveJson(sim, Azure, got.directive)
    doAssert not record["robots"][0].hasKey("pass_to")
    doAssert not record["robots"][1].hasKey("target")
  let full = """{"note":"press high","robots":[
 {"id":"AZ-1","role":"keeper","intent":"hold","target":[-17,0],"kick":"auto","say":"arc"},
 {"id":"AZ-2","role":"striker","intent":"shoot","target":[4,1],"kick":"auto","say":"go"},
 {"id":"AZ-3","role":"wing","intent":"pass","target":[8,-4],"pass_to":"AZ-2","kick":"never","say":"wide"}]}"""
  let gotFull = sim.parseOf(Azure, full)
  doAssert gotFull.usable, gotFull.reason
  doAssert gotFull.directive.note == "press high"
  doAssert gotFull.directive.robots[0].role == roleKeeper
  doAssert gotFull.directive.robots[2].kick == kickNever
  report "minimal and full canonical JSON and standard outer markdown fences parse and omit unused optionals"

proc proseAndTrailingContentRejected() =
  let validBody = """{"note":"press high","robots":[
 {"id":"AZ-1","role":"keeper","intent":"hold","target":[-17,0],"pass_to":null,"kick":"auto"},
 {"id":"AZ-2","role":"striker","intent":"shoot","target":[4,1],"pass_to":null,"kick":"auto"},
 {"id":"AZ-3","role":"wing","intent":"intercept","target":[8,-4],"pass_to":null,"kick":"auto"}]}"""
  for bad in [
    "Sure! Here is my plan:\n```json\n" & validBody & "\n```",
    "```json\n" & validBody & "\n```\nHope that helps!",
    "Plan: " & validBody,
    validBody & " trailing",
    validBody & "\n" & validBody,
    "```yaml\n" & validBody & "\n```",
    "I am not going to answer that."
  ]:
    let proposal = jsonProposal(bad)
    doAssert not proposal.ok, "unexpectedly accepted non-canonical wrapper: " & bad
  report "prose prefixes, suffixes, trailing JSON, and non-JSON fences are rejected"

proc objectKeyedRobotsRejected() =
  var sim = playing(testConfig())
  let text = """{"note":"","robots":{
    "AZ-3":{"role":"striker","intent":"chase","target":[0,0],"kick":"auto"},
    "AZ-1":{"role":"keeper","intent":"hold","target":[-18,1.5],"kick":"auto"},
    "AZ-2":{"role":"back","intent":"press","target":[2,2],"kick":"auto"}}}"""
  let got = sim.parseOf(Azure, text)
  doAssert not got.usable, "an id-keyed robots object was accepted"
  report "an id-keyed robots object is rejected"

proc invalidEnumsAndPassToRejected() =
  var sim = playing(testConfig())
  for text in [
    """{"note":"x","robots":[
     {"id":"AZ-1","role":"libero","intent":"hold","kick":"auto","target":[0,0]},
     {"id":"AZ-2","role":"back","intent":"clear","kick":"never","target":[0,0]},
     {"id":"AZ-3","role":"wing","intent":"chase","kick":"auto","target":[0,0]}]}""",
    """{"note":"x","robots":[
     {"id":"AZ-1","role":"keeper","intent":"nutmeg","kick":"auto","target":[0,0]},
     {"id":"AZ-2","role":"back","intent":"clear","kick":"never","target":[0,0]},
     {"id":"AZ-3","role":"wing","intent":"chase","kick":"auto","target":[0,0]}]}""",
    """{"note":"x","robots":[
     {"id":"AZ-1","role":"keeper","intent":"hold","kick":"maybe","target":[0,0]},
     {"id":"AZ-2","role":"back","intent":"clear","kick":"never","target":[0,0]},
     {"id":"AZ-3","role":"wing","intent":"chase","kick":"auto","target":[0,0]}]}""",
    """{"note":"x","robots":[
     {"id":"AZ-1","role":"keeper","intent":"hold","kick":"auto","target":[0,0]},
     {"id":"AZ-2","role":"back","intent":"clear","kick":"never","target":[0,0]},
     {"id":"AZ-3","role":"wing","intent":"pass","pass_to":"CR-1","kick":"auto","target":[0,0]}]}""",
    """{"note":"x","robots":[
     {"id":"AZ-1","role":"keeper","intent":"hold","kick":"auto","target":[0,0]},
     {"id":"AZ-2","role":"back","intent":"clear","kick":"never","target":[0,0]},
     {"id":"AZ-3","role":"wing","intent":"pass","pass_to":null,"kick":"auto","target":[0,0]}]}""",
    """{"note":"x","robots":[
     {"id":"AZ-1","intent":"hold","target":[0,0]},
     {"id":"AZ-2","intent":"clear","kick":"never"},
     {"id":"AZ-3","intent":"pass"}]}""",
    """{"note":"x","robots":[
     {"id":"AZ-1","intent":"hold","target":[0,0]},
     {"id":"AZ-2","intent":"clear","kick":null},
     {"id":"AZ-3","intent":"chase"}]}""",
    """{"note":"x","robots":[
     {"id":"AZ-1","role":null,"intent":"hold","target":[0,0]},
     {"id":"AZ-2","intent":"clear"},
     {"id":"AZ-3","intent":"chase"}]}"""
  ]:
    let got = sim.parseOf(Azure, text)
    doAssert not got.usable, "invalid enum or pass_to was accepted: " & text
  report "unknown enums, self/opponent pass_to, and pass without pass_to are rejected"

proc badTargetsRejected() =
  var sim = playing(testConfig())
  for text in [
    """{"note":"x","robots":[
     {"id":"AZ-1","role":"back","intent":"hold","kick":"auto"},
     {"id":"AZ-2","role":"back","intent":"hold","kick":"auto","target":[0,0]},
     {"id":"AZ-3","role":"back","intent":"hold","kick":"auto","target":[0,0]}]}""",
    """{"note":"x","robots":[
     {"id":"AZ-1","role":"back","intent":"hold","kick":"auto","target":[999,-999]},
     {"id":"AZ-2","role":"back","intent":"hold","kick":"auto","target":[0,0]},
     {"id":"AZ-3","role":"back","intent":"hold","kick":"auto","target":[0,0]}]}""",
    """{"note":"x","robots":[
     {"id":"AZ-1","role":"back","intent":"hold","kick":"auto","target":["-18","1.5"]},
     {"id":"AZ-2","role":"back","intent":"hold","kick":"auto","target":[0,0]},
     {"id":"AZ-3","role":"back","intent":"hold","kick":"auto","target":[0,0]}]}""",
    """{"note":"x","robots":[
     {"id":"AZ-1","role":"back","intent":"hold","kick":"auto","target":{"x":0,"y":0}},
     {"id":"AZ-2","role":"back","intent":"hold","kick":"auto","target":[0,0]},
     {"id":"AZ-3","role":"back","intent":"hold","kick":"auto","target":[0,0]}]}"""
  ]:
    let got = sim.parseOf(Azure, text)
    doAssert not got.usable, "invalid target was accepted: " & text
  report "missing, out-of-pitch, string, and object targets are rejected"

proc wrongRobotCountsAndIdsRejected() =
  var sim = playing(testConfig())
  for text in [
    """{"robots":[
      {"id":"AZ-1","role":"keeper","intent":"hold","kick":"auto","target":[1,1]},
      {"id":"AZ-2","role":"striker","intent":"shoot","kick":"auto","target":[2,2]},
      {"id":"AZ-3","role":"wing","intent":"press","kick":"auto","target":[3,3]},
      {"id":"AZ-1","role":"back","intent":"clear","kick":"auto","target":[4,4]}]}""",
    """{"note":"thinking","robots":[]}""",
    """{"robots":[{"id":"AZ-2","role":"back","intent":"clear","kick":"auto","target":[0,0]}]}""",
    """{"robots":[
      {"id":"AZ-1","role":"keeper","intent":"hold","kick":"auto","target":[1,1]},
      {"id":"AZ-1","role":"striker","intent":"shoot","kick":"auto","target":[2,2]},
      {"id":"AZ-3","role":"wing","intent":"press","kick":"auto","target":[3,3]}]}""",
    """{"robots":[
      {"id":"striker","role":"striker","intent":"shoot","kick":"auto","target":[0,0]},
      {"id":"midfield","role":"wing","intent":"press","kick":"auto","target":[0,0]},
      {"id":"sweeper","role":"back","intent":"hold","kick":"auto","target":[0,0]}]}""",
    """{"robots":[
      {"id":"CR-1","role":"keeper","intent":"hold","kick":"auto","target":[0,0]},
      {"id":"CR-2","role":"striker","intent":"shoot","kick":"auto","target":[0,0]},
      {"id":"CR-3","role":"wing","intent":"press","kick":"auto","target":[0,0]}]}"""
  ]:
    let got = sim.parseOf(Azure, text)
    doAssert not got.usable, "invalid robot count or id was accepted: " & text
  report "wrong robot counts, duplicates, invented ids, and wrong-team ids are rejected"

proc runeTruncation() =
  ## A 300-character note truncates to 160 RUNES, and a `say` whose 48th and
  ## 49th characters are a 4-byte emoji lands on the rune boundary — the
  ## result must still round-trip through `%$` -> parseJson and decode as UTF-8.
  var sim = playing(testConfig())
  let longNote = repeat("n", 300)
  # 47 ASCII characters, then two 4-byte emoji: the cut lands between them.
  let say = repeat("s", 47) & "\u{1F3C6}\u{26BD}"
  doAssert say.runeLen == 49
  let text = $(%*{
    "note": longNote,
    "robots": [
      {"id": "AZ-1", "intent": "hold", "target": [0, 0], "say": say},
      {"id": "AZ-2", "intent": "hold", "target": [0, 0], "say": say},
      {"id": "AZ-3", "intent": "hold", "target": [0, 0], "say": say}
    ]
  })
  let got = sim.parseOf(Azure, text)
  doAssert got.usable, got.reason
  doAssert got.directive.note.runeLen == MaxNoteRunes,
    "note truncated to " & $got.directive.note.runeLen & " runes"
  doAssert isValidUtf8(got.directive.note)
  let clipped = got.directive.robots[0].say
  doAssert clipped.runeLen == MaxSayRunes,
    "say truncated to " & $clipped.runeLen & " runes"
  doAssert isValidUtf8(clipped),
    "say was cut mid-character: " & $clipped.len & " bytes"
  doAssert clipped.endsWith("\u2026"), "the cut is not marked"
  # The whole point: it must survive a strict round trip.
  let record = directiveJson(sim, Azure, got.directive)
  let roundTripped = parseJson($record)
  doAssert roundTripped["robots"][0]["say"].getStr() == clipped
  doAssert isValidUtf8($record)
  doAssert capRecord($record).runeLen <= MaxDirectiveRecordRunes
  report "note and say truncate on rune boundaries and round-trip strictly"

proc clipRunesIsExact() =
  doAssert clipRunes("", 10) == ""
  doAssert clipRunes("abc", 10) == "abc"
  doAssert clipRunes("abcdef", 3).runeLen == 3
  # Control characters never reach the replay.
  doAssert clipRunes("a\x07b\nc", 10) == "abc"
  # A pure-emoji string truncates on codepoints, not bytes.
  let emoji = repeat("\u{1F3C6}", 20)
  doAssert emoji.len == 80
  let cut = clipRunes(emoji, 5)
  doAssert cut.runeLen == 5
  doAssert isValidUtf8(cut)
  report "clipRunes counts codepoints, strips control characters and marks the cut"

proc idParsing() =
  doAssert robotIndexOfId("AZ-1") == 0
  doAssert robotIndexOfId("AZ-3") == 2
  doAssert robotIndexOfId("CR-1") == 3
  doAssert robotIndexOfId("CR-2") == 4
  doAssert robotIndexOfId("az-3") == -1
  doAssert robotIndexOfId(" cr 2 ") == -1
  doAssert robotIndexOfId("AZ-4") == -1
  doAssert robotIndexOfId("XX-1") == -1
  doAssert robotIndexOfId("") == -1
  for i in 0 ..< RobotCount:
    doAssert robotIndexOfId(robotId(i)) == i
  report "robot ids match canonical AZ-1..3 / CR-1..3 strictly"

proc capRecordStaysParseable() =
  var sim = playing(testConfig())
  for quoteSaturated in ["\"", "\\"]:
    var directive = sim.policyView().formationDirective(Azure, 39)
    directive.source = dsLlm
    directive.latencyMs = 12345
    directive.note = clipRunes(repeat(quoteSaturated, MaxNoteRunes),
      MaxNoteRunes)
    for slot in 0 ..< RobotsPerSeat:
      directive.robots[slot].say =
        clipRunes(repeat(quoteSaturated, MaxSayRunes), MaxSayRunes)
      directive.robots[slot].passTo =
        int32(firstRobotOf(Azure) + ((slot + 1) mod RobotsPerSeat))
    let raw = $directiveJson(sim, Azure, directive)
    doAssert raw.runeLen > MaxDirectiveRecordRunes,
      "the quote-saturated bound no longer exceeds the cap (" &
        $raw.runeLen & " runes); this test is measuring nothing"
    let capped = capRecord(raw)
    doAssert capped.runeLen <= MaxDirectiveRecordRunes,
      "capRecord returned " & $capped.runeLen & " runes"
    doAssert isValidUtf8(capped), "capRecord cut a character in half"
    let node = parseJson(capped)
    doAssert node{"k"}.getStr() == "directive"
    doAssert node{"seat"}.getInt() == ord(Azure)
    doAssert node{"source"}.getStr() == "llm"
    doAssert node{"turn"}.getInt() == 39
    doAssert node{"robots"}.len == RobotsPerSeat
    doAssert node{"note"}.getStr().len > 0,
      "the shrink threw the note away entirely"
    for entry in node{"robots"}:
      doAssert entry{"id"}.getStr().len == 4
      doAssert entry{"intent"}.getStr().len > 0
    var feedSim = playing(testConfig())
    let before = feedSim.feed.len
    feedSim.applyRecord(capped)
    doAssert feedSim.feed.len > before,
      "the capped record no longer reaches the broadcast feed"
  let small = """{"k":"directive","turn":1,"seat":0,"note":"tidy"}"""
  doAssert capRecord(small) == small
  report "a quote-saturated directive record caps to parseable JSON"

when isMainModule:
  echo "test_directives"
  idParsing()
  clipRunesIsExact()
  validCanonicalAndFenced()
  proseAndTrailingContentRejected()
  objectKeyedRobotsRejected()
  invalidEnumsAndPassToRejected()
  badTargetsRejected()
  wrongRobotCountsAndIdsRejected()
  runeTruncation()
  capRecordStaysParseable()
  echo "test_directives: all good"
