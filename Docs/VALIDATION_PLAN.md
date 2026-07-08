# Validation plan

## Objective

Validate whether an iPhone microphone can produce repeatable mechanical watch rate estimates under controlled conditions.

## Test watches

Start with 2–3 watches:

1. A known stable 28,800 bph mechanical watch.
2. A vintage Seiko / King Seiko style watch.
3. A noisier or quieter watch to test failure cases.

## Test protocol

For each watch:

1. Quiet room.
2. Same position.
3. Same iPhone.
4. Watch crown or caseback near microphone.
5. Run five 60-second measurements.
6. Record:
   - selected BPH
   - measured BPH
   - sec/day
   - signal quality
   - valid peaks
   - outlier ratio

## Pass criteria

The app is promising if high-confidence measurements repeat within approximately ±3–5 sec/day.

## Fail criteria

The app is not ready if:

- results jump wildly between repeated measurements;
- low-quality measurements still show confident numbers;
- quiet watches cannot be detected at all;
- Bluetooth microphone routing causes hidden bad measurements.
