# Atmos itinerary demo

From the repository root, run the following with Node.js 22.18 or later and open [the local dashboard](http://127.0.0.1:4317). The server uses Node’s built-in SQLite driver and requires no package installation.

```sh
node Atmos/Demo/server.mjs
```

## Replay the trip

1. Open **Start trip briefing**. Read the prefilled Richmond/Singapore request, type an edit, or dictate on a browser that supports speech recognition. Select **Build my day**. The demo understands the SF hackathon scenario and extracts supported trip details, budget and step goals. Open **Preferences in memory** to inspect the result.
2. Select a transport icon and a breakfast. Replay the simulated trip from the Richmond pickup. Google Maps links open the selected legs. The tracker adjusts departure times, walking and fares from the chosen stops.
3. Compare the host’s lunch with the nearby alternatives. Each stop includes its evidence, ingredient caveats and available information about queues. Select dinner and prepare a reservation or invitation draft.
4. Confirm nightlife to reveal the fictional team post. You can also use **Show interruption**. The demo matches the transcribed restaurant and street signs in the generated photo to a fictional venue. Accept the alternative to change dinner and update the evening route. Dinner-specific drafts clear when their venue changes.
5. Compare estimated spend and walking with the saved goals. **Spending log** records actual test expenses. **Recall a memory** can search the visitor’s plan or the shared guide. Use **Reset demo** to replay the trip in the current browser.

The replay covers Friday, November 20 through Sunday, November 22, 2026. Friday’s event, venue, menus and nightlife listings have source links. Saturday and Sunday have suggested outings. The home location, contacts and social posts are fictional. Transit durations use approximate coordinates and grid distances. Fares for rideshare are planning allowances. Walking estimates use 1,350 steps per km on planned walking legs and 0.04 kcal per step. The Friday budget includes selected stops and modeled inter-stop fares. A return journey, optional drinks and purchases are outside that projection. Invitations, payments and reservations stay in the local demo.

## Native macOS entry

With the local server running, build a separate test app from this branch on an Apple silicon Mac meeting the [Atmos requirements](../README.md). Quit another running copy of Atmos before starting the test executable.

```sh
bash Atmos/Scripts/build.sh /tmp/Atmos-Itinerary.app
ATMOS_ITINERARY_DEMO=1 /tmp/Atmos-Itinerary.app/Contents/MacOS/Atmos
```

Say **Hey Atmos** and give the sample Richmond hackathon itinerary request, or type it in the native command field. The opt-in handler delivers the briefing to the loopback service and opens the dashboard using a single-use ticket. The bundled prebuilt app predates this feature. The browser entry runs independently on Windows or macOS.

## Data and source refresh

The local SQLite database in `.sandbox/` stores shared guide evidence and a separate itinerary for each browser session. An HttpOnly cookie identifies the visitor. Use another browser profile to test isolation. Set `ATMOS_DEMO_DB` to choose a test database or `ATMOS_DEMO_PORT` to change port 4317. The native app and the server must use the same port.

With `ATMOS_DEMO_LIVE_SOURCES=1`, the running server checks the Luma event, the SF menu PDF and the National Weather Service hourly forecast at startup and every 30 minutes. The observer stores the last successful reading, check time and change time. A menu revision signals that the published document changed. Restaurant inventory, queues and delivery or reservation availability require their own data sources. The demo’s archived itinerary remains reproducible.

For an optional Cognee integration test, set **both** `ATMOS_TEST_COGNEE_URL` and `ATMOS_TEST_COGNEE_KEY` in the server process environment using a dedicated test tenant. The default is local SQLite recall. The worker indexes the shared reference guide and an allowlisted projection of each visitor’s preferences and choices into separate test datasets. Briefings, workplace notes, expenses and social drafts stay in SQLite. Keep the database while a cloud deletion is pending so the worker can complete it when reconnected. [Cognee HTTP documentation](https://docs.cognee.ai/api-reference/introduction)

Run the behavioral tests from the repository root.

```sh
node --test Atmos/Demo/demo.test.mjs Atmos/Demo/memory.test.mjs Atmos/Demo/observer.test.mjs
```

The building photo is by Gianluca Cogoli (CC BY 3.0, resized). The Golden Gate Bridge photo is by Rich Niewiroski Jr. (CC BY 2.5). Restaurant photos link to the venue’s own images. The team dinner and conference images were generated for fictional social posts. [Building photo and license](https://commons.wikimedia.org/wiki/File:Looking_up,_525_Market,_SF.jpg) · [Bridge photo and license](https://commons.wikimedia.org/wiki/File:GoldenGateBridge-001.jpg)
