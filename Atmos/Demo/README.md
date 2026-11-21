# Atmos itinerary demo

Atmos is a city companion for travelers. The platform idea pairs shared city memory with private traveler memory. Background agents would keep track of event schedules, restaurant openings and closures, menus, prices and availability. A traveler can give Atmos a plain-language briefing, then use those facts alongside their dietary needs, schedule, spending limit, walking goal and social plans to choose a day in the city.

This local San Francisco demo follows a first-time visitor from Singapore attending a hackathon. The map, menu photos, transport comparisons, trip tracker and simulated dinner invitations make each decision visible. Selected event, menu and weather sources can refresh while the test server runs. Social posts, messages and bookings are simulated, and pickup and walking times are estimates.

From the repository root, run the following with Node.js 22.18 or later and open [the local dashboard](http://127.0.0.1:4317). The server uses Node’s built-in SQLite driver and requires no package installation.

```sh
node Atmos/Demo/server.mjs
```

## Replay the trip

1. At the home page, paste or dictate the San Francisco trip request and select **Plan my day**. After the route calculation screen, the map opens at the simulated Richmond District pickup. Tap a transport icon to compare the wait, duration and fare. **Trip briefing** reopens the request. Later, choose **Resume saved day** from home or reload the itinerary to continue. [MacBook presenter guide](MAC_DEMO.md)
2. Tap a named option in breakfast, hackathon, lunch, dinner or nightlife. Each opens its menu or venue gallery inline. The green check adds that choice to the route. The red × returns to the options and preserves the saved route. After confirming, use the gray return arrow to compare alternatives. **Menu & dietary details** includes sources, directions and an optional **Skip this meal** for confirmed meals.
3. Under **People nearby**, select **Invite both to dinner**. Review the recipients, venue, address and time, then select **Approve to send**. A simulated iMessage conversation opens beside the route. The local history keeps the approved wording if dinner changes later. Use **View messages** to reopen it.
4. After lunch the traveler returns to the hackathon. **Travel to dinner** starts at the Loft after closing. **Travel to nightlife** starts at the selected restaurant, or at the Loft if dinner is skipped. Choose **Walk** or a ride on either leg, then confirm to update directions, arrival times, costs and steps.
5. Tap **Tech Afterhours SF** with the sample briefing to open the boss’s fictional X post. **Keep my plan** returns to the event preview. **Reroute my evening** changes dinner and updates the travel legs. **Trip tools** also includes a manual replay.
6. Use **Trip tools** to record expenses, check sources or search memory. **Reset demo** clears this browser’s test itinerary and message history.

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
node --test "Atmos/Demo/*.test.mjs"
```

Each menu photo opens its venue or manufacturer attribution. The ride details link to the source of the selected service icon. The local map uses OpenStreetMap data, OpenFreeMap and OpenMapTiles. Its downtown 38R segment follows the SFMTA route geometry. Dotted segments illustrate connections between stops. [OpenStreetMap attribution](https://www.openstreetmap.org/copyright) · [SFMTA route data](https://data.sf.gov/d/9exe-acju)

The building photo is by Gianluca Cogoli (CC BY 3.0, resized). The Golden Gate Bridge photo is by Rich Niewiroski Jr. (CC BY 2.5). The team dinner and conference images were generated for fictional social posts. [Building photo and license](https://commons.wikimedia.org/wiki/File:Looking_up,_525_Market,_SF.jpg) · [Bridge photo and license](https://commons.wikimedia.org/wiki/File:GoldenGateBridge-001.jpg)
