# Atmos itinerary demo

From the repository root, run the following with Node.js 22.18 or later and open [the local dashboard](http://127.0.0.1:4317). The server uses Node’s built-in SQLite driver and requires no package installation.

```sh
node Atmos/Demo/server.mjs
```

## Replay the trip

1. The map opens at the simulated Richmond District pickup, with a clock in San Francisco time. Choose a ride, or open **Trip briefing** to edit or dictate the sample itinerary request. After building the day, the briefing includes Atmos’s reply and optional read-aloud.
2. Open any stop name to change the venue, inspect dietary information and sources, or get directions. Menu photos show examples offered by the venue. Tap a green check to skip that meal or its red × to restore it. The tracker recalculates the route and estimates.
3. Under **People nearby**, select **Invite both to dinner**. Review the recipients, venue, address and time, then select **Approve to send**. A simulated iMessage conversation opens beside the route. The local history keeps the approved wording if dinner changes later. Use **View messages** to reopen it.
4. Select a nightlife option or use **Show demo notification** in **Trip tools** to replay the fictional team post. The demo matches the transcribed restaurant and street signs in the generated photo to a fictional venue. Accept the alternative to update dinner and the evening route.
5. Use **Trip tools** to record expenses, check sources or search memory. **Reset demo** clears this browser’s test itinerary and message history.

The Friday replay is dated November 20, 2026. The clock shows current San Francisco time. The event, menus and nightlife listings include sources. The home location, social posts and group messages are fictional. Transit times and rideshare prices are planning estimates. Walking estimates use 1,350 steps per km and 0.04 kcal per step. The Friday budget includes selected stops and modeled inter-stop fares. A return journey, optional drinks and purchases are outside that projection.

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

Each menu photo opens its venue or manufacturer attribution. The ride details link to the source of the selected service icon. The local map uses OpenStreetMap data, OpenFreeMap and OpenMapTiles. Its downtown 38R segment follows the SFMTA route geometry. Dotted segments illustrate connections between stops. [OpenStreetMap attribution](https://www.openstreetmap.org/copyright) · [SFMTA route data](https://data.sf.gov/d/9exe-acju)

The building photo is by Gianluca Cogoli (CC BY 3.0, resized). The Golden Gate Bridge photo is by Rich Niewiroski Jr. (CC BY 2.5). The team dinner and conference images were generated for fictional social posts. [Building photo and license](https://commons.wikimedia.org/wiki/File:Looking_up,_525_Market,_SF.jpg) · [Bridge photo and license](https://commons.wikimedia.org/wiki/File:GoldenGateBridge-001.jpg)
