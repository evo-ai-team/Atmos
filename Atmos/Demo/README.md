# Atmos itinerary demo

Atmos is a city companion for travelers. The platform idea pairs shared city memory with private traveler memory. Background agents would keep track of event schedules, restaurant openings and closures, menus, prices and availability. A traveler can give Atmos a plain-language briefing, then use those facts alongside their dietary needs, schedule, spending limit, walking goal and social plans to choose a day in the city.

This local San Francisco demo follows a first-time visitor from Singapore attending a hackathon. The map, menu photos, transport comparisons, trip tracker and dinner invitation drafts make each decision visible. Selected event, menu and weather sources can refresh while the test server runs. Social posts and bookings are simulated, and pickup and walking times are estimates.

From the repository root, run the following with Node.js 22.18 or later and open [the local dashboard](http://127.0.0.1:4317). The server uses Node’s built-in SQLite driver and requires no package installation.

```sh
node Atmos/Demo/server.mjs
```

## Replay the trip

1. At the home page, paste or dictate the San Francisco trip request and select **Plan my day**. After the route calculation screen, the map opens at the simulated Richmond District pickup. Tap a transport icon to compare the wait, duration and fare. **Trip briefing** opens a blank field for new instructions. **Explore trip options** opens the menus directly. Reloading starts a fresh visit. [MacBook presenter guide](MAC_DEMO.md)
2. Tap a named option in breakfast, hackathon, lunch, dinner or nightlife. Each opens its menu or venue gallery inline. The green check adds that choice to the route. The red × returns to the options and preserves the saved route. After confirming, use the gray return arrow to compare alternatives. **Menu & dietary details** includes sources, directions and an optional **Skip this meal** for confirmed meals.
3. Confirm a dinner venue, then select **Preview dinner invitation** under **People nearby** to read the draft for Gio and Andrew. **Done** closes it. The demo has no send action.
4. After lunch the traveler returns to the hackathon. **Travel to dinner** starts at the Loft after closing. **Travel to nightlife** starts at the selected restaurant, or at the Loft if dinner is skipped. Choose **Walk** or a ride on either leg, then confirm to update directions, arrival times, costs and steps.
5. Tap **Tech Afterhours SF** with the sample briefing to open the boss’s fictional X post. **Keep my plan** returns to the event preview. **Reroute my evening** changes dinner and updates the travel legs. **Trip tools** also includes a manual replay.
6. Use **Trip tools** to record expenses, check sources or search memory. **Reset demo** clears the current visit and queues removal of its synced choices when applicable.

The Friday replay is dated November 20, 2026. The clock shows current San Francisco time. The event, menus and nightlife listings include sources. The home location, social posts and invitation drafts are fictional. Transit times and rideshare prices are planning estimates. Walking estimates use 1,350 steps per km and 0.04 kcal per step. The Friday budget includes selected stops and modeled inter-stop fares. A return journey, optional drinks and purchases are outside that projection.

## Native macOS entry

With the local server running, build a separate test app from this branch on an Apple silicon Mac meeting the [Atmos requirements](../README.md). Quit another running copy of Atmos before starting the test executable.

```sh
bash Atmos/Scripts/build.sh /tmp/Atmos-Itinerary.app
ATMOS_ITINERARY_DEMO=1 /tmp/Atmos-Itinerary.app/Contents/MacOS/Atmos
```

Say **Hey Atmos** and give the sample Richmond hackathon itinerary request, or type it in the native command field. The opt-in handler delivers the briefing to the loopback service and opens the dashboard using a single-use ticket. The bundled prebuilt app predates this feature. The browser entry runs independently on Windows or macOS.

## Data and source refresh

The local SQLite database in `.sandbox/` stores the shared guide, source checks and the sync queue. Each page holds a temporary visit key in JavaScript memory. Briefing text is discarded after parsing. Parsed preferences, expenses and drafts are held in server memory for that visit, which expires after four hours of inactivity. Refreshing the page or opening a new tab starts with empty choices. Set `ATMOS_DEMO_DB` to choose a test database or `ATMOS_DEMO_PORT` to change port 4317. The native app and the server must use the same port.

With `ATMOS_DEMO_LIVE_SOURCES=1`, the running server checks the Luma event, the SF menu PDF and the National Weather Service hourly forecast at startup and every 30 minutes. The observer stores the last successful reading, check time and change time. A menu revision signals that the published document changed. Restaurant inventory, queues and delivery or reservation availability require their own data sources. The demo’s archived itinerary remains reproducible.

For an optional Cognee integration test, set **both** `ATMOS_TEST_COGNEE_URL` and `ATMOS_TEST_COGNEE_KEY` in the server process environment using a dedicated test tenant. Local searches cover the shared guide and the current visit. The worker indexes the reference guide and explicitly confirmed or skipped itinerary choices in separate test datasets. Starting a briefing creates no visitor sync job. Keep the database while a cloud deletion is pending so the worker can complete it when reconnected. [Cognee HTTP documentation](https://docs.cognee.ai/api-reference/introduction)

Run the behavioral tests from the repository root.

```sh
node --test "Atmos/Demo/*.test.mjs"
```

Confirm any lunch option to open Gio’s demo Instagram story and Andrew’s demo X post together. Both posts can be reopened from **People nearby**.

Preview a transport option to see its path in the card and on the main map. Cancel returns to the confirmed mode, or to the map with no route if this leg has no confirmed mode. The morning, dinner and nightlife maps use the selected stops. The GPS replay follows the displayed path. Walking and example driving paths follow SF Public Works street centerlines. Muni examples use published route alignments with approximate walking connections. Driving alternatives illustrate the demo and carry no provider routing guarantee. The map works offline. Regenerate its bundled paths with `python scripts/build-route-shapes.py` from the Demo directory. [Street centerlines](https://data.sf.gov/d/3psu-pn9h) · [SFMTA alignments](https://data.sf.gov/d/9exe-acju)

Each menu photo opens its venue or manufacturer attribution. Ride details link to the source of the selected service icon. The basemap uses OpenStreetMap, OpenFreeMap and OpenMapTiles. [OpenStreetMap attribution](https://www.openstreetmap.org/copyright)

The building photo is by Gianluca Cogoli (CC BY 3.0, resized). The Golden Gate Bridge photo is by Rich Niewiroski Jr. (CC BY 2.5). The team dinner and conference images were generated for fictional social posts. [Building photo and license](https://commons.wikimedia.org/wiki/File:Looking_up,_525_Market,_SF.jpg) · [Bridge photo and license](https://commons.wikimedia.org/wiki/File:GoldenGateBridge-001.jpg)
