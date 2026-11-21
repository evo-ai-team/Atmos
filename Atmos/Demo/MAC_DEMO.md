# Present the Atmos demo on a MacBook

A traveler can tell Atmos about their day once. Atmos combines the traveler’s preferences with a shared city guide, then updates the route, budget and proposed invitations as the traveler makes decisions.

Allow about five minutes on screen after setup. Drive the app through its visible controls. Pause at the invitation preview, the posted photo and the changed tracker so the audience can see what caused each change.

## Before the audience joins

1. Check out the `codex/atmos-itinerary-demo` branch of `evo-ai-team/Atmos`. On an existing checkout, run `git pull --ff-only` on that branch to get the latest opening screen. Open Terminal in the folder **containing** `Atmos/`. A quick check is `ls Atmos/Demo/server.mjs`. Use Node.js 22.18 or later (`node --version`). The dashboard uses built-in SQLite and needs no package install.
2. In Terminal 1, start a fresh local rehearsal. Leave this process running. This command gives the run its own database, enables public source checks and keeps memory on the Mac.

   ```sh
   demo_state="$(mktemp -d)"
   env -u ATMOS_TEST_COGNEE_URL -u ATMOS_TEST_COGNEE_KEY \
     ATMOS_DEMO_DB="$demo_state/itinerary.sqlite" ATMOS_DEMO_LIVE_SOURCES=1 \
     node Atmos/Demo/server.mjs
   ```

3. Choose an opening. **Browser** is the quickest for an LLM operating alone. In Terminal 2 run `open http://127.0.0.1:4317/`. Maximize the window so **People nearby** and **Trip tracker** fit on the right. **Native voice** also demonstrates the Mac-to-browser handoff. On an Apple silicon Mac with macOS 26+ and full Xcode 27, quit any other Atmos instance, open Terminal 2 in the same source folder, and build and launch the test app.

   ```sh
   demo_app="$(mktemp -d)/Atmos-Itinerary.app"
   bash Atmos/Scripts/build.sh "$demo_app"
   ATMOS_ITINERARY_DEMO=1 "$demo_app/Contents/MacOS/Atmos"
   ```

   For voice, allow microphone access, let the English (US) speech assets finish loading and close the expanded menu before using the wake phrase. The native typed command uses the same local handoff.

   Before the audience joins, open the root URL `http://127.0.0.1:4317/` and leave the blank prompt on screen. This address always opens the home screen. Use **Explore trip options** to open the dashboard with an empty tracker. Reloading the dashboard starts a fresh rehearsal.

## The five-minute walkthrough

### 1. Give Atmos the traveler’s brief

**Say or enter the following as one request.**

> Hey Atmos, plan my itinerary. I’m staying in the Richmond District of San Francisco. I’m here from Singapore for work, it’s my first time here, and I’m in town through Sunday. I signed up for the hackathon at the AWS Loft and told my boss I was sick today so I could attend. I want to meet people, try the local food and go out for drinks tonight. I’m vegan, dairy-free and gluten-free. I like coffee around 8 AM. I want to spend under $400 and walk at least 2,000 steps.

- **In the browser**, paste the request into the empty prompt on the home screen. Pause so the audience can read it, then click **Plan my day**.
- **In the native app**, say “Hey Atmos,” then speak the rest. To type it, choose **Open Atmos Menu**, paste the request under **Let’s Plan Your Day**, and press Return. The default browser opens with the submitted briefing.

**Let the audience watch the reveal.** The **Calculating routes** screen plays, then the itinerary appears automatically. Point to the Richmond pickup, the San Francisco clock and the day’s stops. The clock shows local time, while the route replays Friday, November 20, 2026. Open **Trip briefing → Atmos’ itinerary** for the response, then close the briefing.

### 2. Pick breakfast, then show how it changes the morning ride

Under **Breakfast**, preview **Boichik Bagels · Battery Street** at **22 Battery St**. Pause on the bagel and beverage photos. Open **Menu & dietary details** to show the evidence behind the recommendation, then close the details and click the green check. Choose Battery Street first so the comparison uses that destination.

Scroll up to **Transportation**. Preview **Waymo** to show its example driving route, pickup wait and fare. Click the red × to return to the map with no selected route. Preview **Muni** and watch the path switch to the **38R Geary Rapid** with walking connections. Confirm with the green check. The gray return arrow lets the traveler compare another mode.

### 3. Anchor the day at the hackathon and pick lunch

Open **Hackathon → Personal Agents Hackathon** and confirm the event. Under **Lunch**, open **MIXT**, show its menu and dietary sources, and confirm. **Friends in San Francisco** opens automatically with Gio’s Instagram story from the Golden Gate Bridge and Andrew’s X post from the SF Systems Forum. Select **Back to my trip** to return to the confirmed lunch.

### 4. Choose dinner and make the walking goal visible

Under **Dinner**, select **Oren’s Hummus**, **71 3rd St**, and confirm. In **Travel to dinner**, select **Walk** and confirm. Choose **Totem Game Night** under **Nightlife** and confirm it to compare onward travel. Select **Walk** in **Travel to nightlife**. Leave **Tech Afterhours SF** for step 6.

Point to the dinner arrival time, estimated costs and steps in the tracker. Each confirmed travel leg updates these figures.

### 5. Preview a dinner invitation

In **People nearby**, choose **Preview dinner invitation**. Show the recipients, Oren’s address and the dinner time. Choose **Done** to close the draft. Gio’s and Andrew’s posts can also be reopened from their names.

### 6. Trigger the interruption and reroute

Under **Nightlife**, click the **Tech Afterhours SF** tile once. Opening its preview triggers **Your boss just posted on X**. Pause on “Dinner with the team! :)” and the generated team photo. The demo associates the restaurant sign with the fictional **Ferry Lane Kitchen**, near the Loft. The workplace detail in the briefing makes this interruption relevant.

Click **Reroute my evening**. Show the dinner card and tracker. Dinner changes to **Tacolicious, 741 Valencia St**. The selected walking routes update for the new restaurant. Return to the nightlife preview and confirm **Tech Afterhours SF**.

Open **Preview dinner invitation** again. The draft now uses Tacolicious and the revised dinner time.

### 7. Compare the active visit with a fresh load

Open **Trip tools → Recall a memory**. Set **Search in** to **My trip**, enter `budget`, and click **Search**. Show `budget: 400`. Switch to **City guide** and search `Personal Agents Hackathon`. Show the matching organizer and venue information. For a direct comparison, search `boss` in each scope. The fictional workplace note appears in **My trip** and the city guide returns zero matches. The local demo uses the active visit for personal context and its stored guide for shared facts.

Under **Trip tools → Source checks**, show the status for the event page, menu PDF and hourly weather feed. The observer checks these at startup and every 30 minutes while enabled. Read the check times or fallback status actually displayed. Refresh the current itinerary URL in the same browser. Show the empty tracker and unselected menus. Open **Trip briefing** to show the blank input.

## Presenter notes

- The broader product would use continuously running agents and Cognee-backed memory. This packaged walkthrough demonstrates the local SQLite path. It uses preset preferences and supported briefing fields, a dated city guide, and optional public source checks. The social posts, team-photo match and invitation drafts are scripted demo interactions. Ride waits, fares, steps and calories are estimates.
- If a source is unreachable, present the saved guide and the displayed check status. If the post fails to appear, verify the submitted brief contains both **boss** and **sick**, close any overlays, and preview **Tech Afterhours SF**. **Trip tools** also offers a manual replay.
- If port 4317 is occupied, set `export ATMOS_DEMO_PORT=4318` in **both** terminals before launch and open `http://127.0.0.1:4318/`.
