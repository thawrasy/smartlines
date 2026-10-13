# Testing the station screens with real users

The protocol for the sessions that follow the design review ([STATION_SCREENS_REVIEW.md](STATION_SCREENS_REVIEW.md)),
readiness register item C6. The sessions show whether the people who will work at the pilot station can do their tasks
quickly and without errors on the station's own devices, before the go/no-go of 29 December 2026.

## 1. When and where

- **When:** 7 to 18 December 2026, after the staging gates of 4 December and before the go/no-go of 29 December
  (implementation timeline 2.0). A second, shorter round in the first week of the pilot (from 4 January 2027) repeats
  tasks 1, 3 and 5 under real load.
- **Where:** the pilot station (Damascus Central), at a counter and a bay out of service, or a room set up the same way.
  The system is the staging environment with test data only: test companies, test trips and test passengers.
- **Devices:** the counter's desktop with its barcode scanner and its receipt printer (80 mm); the bay's phone or
  handheld scanner; the hall's screen (1920 × 1080); a mid-range Android phone for passengers. Every device is
  recorded in the device matrix.

## 2. Who takes part

| Group | Number | Recruited from |
| --- | --- | --- |
| Counter clerks of the operating company | 5 | the company that will run the pilot counters |
| Bay staff | 3 | the same company |
| Carrier operations staff | 2 | the pilot carriers |
| Platform operations staff | 2 | the platform's operations team |
| Passengers reading the board | 5 | people waiting in the hall (adults of different ages, at least one older than 60) |

Five participants per main group find most of the problems that block a task. Nobody from the build team takes part.

## 3. Tasks and targets

Each task names the screen, what the participant is told, what counts as success and the target time. The facilitator
reads the task as written and does not show where to click.

| # | Group | Task (as told) | Success | Target |
| --- | --- | --- | --- | --- |
| 1 | Clerk | "This passenger shows a ticket on a phone. Check them in." (identity document given) | Pass printed for the right passenger, with the bay | 20 s per passenger |
| 2 | Clerk | "This passenger has only a ticket number and a booking reference. Check them in." | Pass printed | 45 s |
| 3 | Clerk | "The scanner read the ticket but the pass did not come out. Find out why and fix it." (identity box not ticked) | Box ticked, pass printed, no second scan needed | 30 s |
| 4 | Clerk | "This passenger was checked in a minute ago and lost the pass. Print it again." | Same pass printed, the notice understood | 30 s |
| 5 | Clerk | "A passenger wants the next seat to Aleppo. Sell it for cash." | Sale done, ticket printed with a code or with the time the code is ready | 90 s |
| 6 | Clerk | "Which trips to Aleppo have check-in open now, and until when?" | Correct answer from the trips screen | 15 s |
| 7 | Bay staff | "Board these 10 passengers for the 18:57 trip." (passes on paper and on phones, one not checked in, one already boarded) | 8 boarded, 2 refused with the right reason | 2 min |
| 8 | Carrier | "Give this operating company the right to check in your trips at Damascus Central, then see what it did today." | Right given; activity found | 2 min |
| 9 | Platform | "Open a third counter at Damascus Central for this company and switch the hall's screen on." | Counter opened; board visible | 2 min |
| 10 | Passenger | "Which bay does the next bus to Homs leave from?" (read from 5 m) | Correct bay | 10 s |
| 11 | Passenger | "The bus to Aleppo at 21:37: is it still leaving?" (a cancelled trip) | "Cancelled" understood | 10 s |
| 12 | Station administration | "From today Al-Fajr's buses leave from bay B004; tonight's 23:27 to Aleppo leaves from B002." | Permanent bay set; the trip's bay set; both on the board | 90 s |
| 13 | Driver | "This passenger's paper ticket has no code. Board them." (number and booking reference on the paper) | Boarded after checking the identity document | 45 s |
| 14 | Passenger | "Which bus is yours?" (ticket shows "DC 101"; read it on the board while it changes language) | Correct row found | 15 s |

Tasks 1 to 5 are done in both languages by at least two clerks. Task 7 is done once with the bay's network switched
off for a minute (the board and the bay keep working from what they hold).

## 4. How a session runs

1. **Consent** (2 minutes): the purpose, that the screens are tested and not the person, that the session is recorded
   (screen and voice, no faces) and that no real passenger data is used. Signed consent kept with the test records.
2. **Background** (3 minutes): role, years in the job, devices used today.
3. **Tasks** (25 to 35 minutes): one at a time, thinking aloud. The facilitator only reads tasks and asks "what do you
   expect here?". A second person notes time, errors, hesitations and quotes.
4. **After each task:** one question, "How easy was this task?" on a scale of 1 (very hard) to 7 (very easy).
5. **At the end** (5 minutes): the ten-question System Usability Scale, in Arabic, and two open questions: "What
   slowed you down?" and "What would you change first?".

## 5. What is measured

- task success (done, done with help, not done), time on task, errors (wrong passenger, wrong trip, wrong button);
- the ease score of each task, and the System Usability Scale score of each group;
- every problem seen, with the task, the screen, how many participants met it and a severity on the review's scale
  (critical, high, medium, low).

**Exit criteria for the pilot:** no critical problem open; every high problem fixed or accepted by the owner in writing;
tasks 1, 5 and 7 within target for at least four of five clerks or three of three bay staff; System Usability Scale of
70 or more for clerks and bay staff.

## 6. After the sessions

Within five working days: a findings list in the review's format (screen, problem, severity, how many met it,
proposal), the fixes planned against the timeline, and the readiness register updated (C6). Recordings are deleted
30 days after the findings are accepted; the notes keep no names.

## 7. Preparation checklist

- [ ] Staging environment with boarding stations on at the pilot station, its counters, bays and screens
- [ ] Test operating company, carriers, trips at the right times (one boarding, one with check-in open, one without a
      bay, one cancelled), test passengers with tickets on phones and on paper
- [ ] Clerks' and bay staff's accounts with their second factor set up on the station's devices
- [ ] Scanner, receipt printer, bay phone and hall screen connected and listed in the device matrix
- [ ] Consent forms, task cards in Arabic and English, the observer's sheet, the questionnaire
- [ ] A quiet place next to the counter for the sessions, and a way to switch the bay's network off for task 7
