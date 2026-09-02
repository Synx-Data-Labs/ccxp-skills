---
estimation: 2h
status: Design
scheduled: 2026-06-18
priority: P2
source: hallway chat
---

# T20260615-654321 — Make the scanner faster

## Problem

The scanner in scripts/scan-runtime-libs.sh is slow. It should be faster. We
think it walks too much but have not measured it.

## Plan

Speed it up somehow. Maybe cache results. TODO: figure out the actual approach
once we look at the profiler.

## Done criteria

- [ ] The scanner is faster.
- [ ] Users are happy.

## Closed

_(pending)_
