# LimitBreak

An RPG progression layer welded onto a serious strength-training log.

Every rep is XP, every PR is a **LimitBreak**, and the whole thing is coached by
an agent that reads your actual training history before it opens its mouth.
iPhone, iPad, Apple Watch, widgets, and a Live Activity — SwiftUI throughout,
SwiftData with CloudKit mirroring, iOS 26.

---

## The idea

Most lifting apps are spreadsheets with a tint colour. LimitBreak is a
spreadsheet with **consequences**: skip four days and you watch a level fall off.
The progression system is not decoration bolted onto the log — it *is* the log,
read back a different way.

Nothing about the game layer is stored. Levels, ranks, mastery, streaks and
recovery are all recomputed from the sessions themselves, so there is no ledger
to corrupt, migrate, or disagree with reality.

## Progression

| Action | XP |
|---|---|
| Finish a session | 25 + 10/working set + 3/warmup + 1 per 100 lb volume |
| Set a personal record | 50 (a **LimitBreak**) |
| Play a sport | 25 + 7/minute |
| Log a walk | 15 |
| Close a 10k step day | 50 |
| Rank up a movement or routine | 500 / 1000 |

A level costs `100 + 50 × level`. Ranks run **Novice → Squire → Adventurer →
Warrior → Berserker → Champion → Warlord → Titan → Raid Boss**.

Train every day and a streak multiplier compounds: `1 + days/7`, so week two pays
double and week three triple. Go quiet and, after two grace days, idle decay
takes 10 XP a day — enough to drop a level, which the timeline records in crimson
as **LEVEL LOST**. Streaks survive exactly one quiet day. A walk has to cover a
mile to count.

## Training

Six tracking types — weight and reps, bodyweight, duration and reps,
hold-for-time, time and distance, and a custom metric — with per-rep weight
capture, warmup flagging, and a reps-in-reserve read taken as each movement
finishes.

- **Supersets** that suppress the rest timer until every movement in the pair has
  been logged.
- **A rest timer built on a deadline**, not a tick count, so backgrounding the app
  doesn't lie to you.
- **Hold timer** with a 3-2-1 prep phase for planks and dead hangs.
- **PR detection across six record dimensions**, celebrated with a particle
  shatter and a bespoke CoreHaptics charge-and-break pattern.
- **Retroactive logging** and full history editing — records recompute afterward.
- **Walks** tracked by GPS or drawn on the map with a finger, exported to Health
  as a real workout route.

Plus a 264-movement library with per-movement 1RM formula, load style, and unit;
a routine builder; a weekly plan board; and an animated posed figure that
demonstrates the movement instead of showing a still.

## The coach

A three-tier agent behind one protocol, chosen by what's configured and
reachable:

1. **Claude** — native tool use, server-enforced schemas.
2. **Self-hosted** — a local LLM given the tool contract as prose. *Currently
   dormant.*
3. **Apple Foundation Models** — on-device, free, works in a basement gym with no
   signal.

All three see the **same 21 tools** — nine that read your training, twelve that
change it — and every mutating call is staged as a card you approve or decline
before anything is written. Cloud access is off by default; nothing leaves the
device until you turn it on.

The important part is what the model *isn't* trusted with. It picks movements and
session shape; every prescribed weight is then overwritten by the progression
engine from your own logged history — double progression with undulating
heavy/volume emphasis, stall detection at three flat sessions, and a 10% deload.
A coach that hallucinates a number can't put it on your bar.

## Analytics

A 22-week activity matrix, three power dials (volume against last week, sessions
against goal, and what fraction of you is recovered), an eight-week push/pull/
legs/core volume chart, and front-and-back body diagrams coloured by freshness —
red under a day, amber to two, teal to a week, then dormant. Tap any muscle for
every set that hit it.

Mastery is separate and earned by showing up: five completions per rank, per
movement and per routine, **Practiced → Grandmaster**.

## Platform

- **Apple Watch** — a thin remote over WatchConnectivity; start a routine, log the
  next set, advance, finish.
- **Widgets** — five of them, including an extra-large dashboard, plus lock-screen
  streak and step complications.
- **Live Activity** — Dynamic Island with a working LOG SET button and a live rest
  countdown.
- **Siri** — level, last workout, last walk, last activity.
- **HealthKit** — writes strength sessions and walks with routes and energy;
  reads steps, body mass, and active energy.
- **iPad** — purpose-built multi-column layouts per tab, not a stretched phone.

## Building

Open `LimitBreak.xcodeproj` and run. Requires Xcode 26+ and an iOS 26 device or
simulator. The exercise library seeds itself on first launch and merges new
movements on update, never touching anything you created yourself.

Optional: an Anthropic API key in Settings enables the cloud coach. It's stored in
the keychain, device-only, and never leaves for anywhere but Anthropic.
