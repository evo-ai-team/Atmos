// The trip is replayed on the host's local calendar day, Friday 20 November 2026.
// Origin and walking budgets are scenario inputs. Provider prices and times are
// dated observations or explicitly identified allowances.
const link = (label, url) => ({ label, url });
const maps = (from, to, mode) => "https://www.google.com/maps/dir/?" +
  new URLSearchParams({ api: "1", origin: from, destination: to, travelmode: mode });

export const origin = "327½ 14th Avenue, Apt. Atlas (fictional), Richmond District, San Francisco";
// Navigation uses a public cross street near the fictional apartment.
const pickup = "Clement Street and 14th Avenue, San Francisco, CA";
export const originCoords = [37.78288, -122.47290];
const loft = "525 Market St, 2nd floor, San Francisco, CA 94105";
const loftMap = link("AWS venue pin on Google Maps", "https://maps.app.goo.gl/rXg15QRsDQqnFYMD8");
const routePage = link("SFMTA · 38R route and stops", "https://www.sfmta.com/routes/38r-geary-rapid");
const farePage = link("SFMTA · fares and payment", "https://www.sfmta.com/getting-around/muni/fares");
const originDirections = (mode) => maps(pickup, loft, mode);
const fromLoft = (to) => maps(loft, to + ", San Francisco, CA", "walking");
const weatherPage = link("National Weather Service · Nov 20, 2:02 PM bulletin", "https://api.weather.gov/products/5b3e3fe8-0885-4ed1-b00f-35777776562e");

export const event = {
  id: "personal-agents-hackathon",
  title: "Personal Agents Hackathon",
  address: loft,
  coords: [37.7903213, -122.399369],
  date: "2026-11-20",
  starts: "09:30",
  ends: "19:30",
  time: "9:30 AM–7:30 PM PST",
  price: 0,
  notes: "Enter the courtyard at 525 Market and go to the second-floor AWS Builder Loft. Doors and opening remarks at 9:30 AM, hacking at 11 AM, lunch at 1:30 PM, submissions at 4:30 PM, finalist demos at 5 PM, awards at 7 PM. Bring your registration approval and physical government-issued photo ID. Ages 18+.",
  image: "/assets/525-market.jpg",
  imageCredit: "Looking up, 525 Market, SF · Gianluca Cogoli, CC BY 3.0. Resized from the original.",
  sources: [
    link("Luma · host agenda and entry requirements", "https://luma.com/personalagenthack"),
    link("AWS · Builder Loft event calendar", "https://builder.aws.com/connect/events?tag=builder-loft-SF"),
    link("AWS · venue and courtyard entrance", "https://startups.aws.com/lp/aws-gen-ai-loft-san-francisco?lang=en-US"),
    loftMap,
    link("Wikimedia Commons · building photograph", "https://commons.wikimedia.org/wiki/File:Looking_up,_525_Market,_SF.jpg"),
    link("Photograph license · CC BY 3.0", "https://creativecommons.org/licenses/by/3.0/"),
  ],
};

export const transit = [
  {
    id: "muni", title: "38R Geary Rapid", address: "Geary Blvd & Park Presidio Blvd → Market St & 1st St",
    time: "07:50", minutes: 43, steps: 1050, price: 2.85,
    payment: "Tap Clipper, a contactless bank card or a mobile wallet on boarding. Exact cash is $3.",
    notes: "Walk south to the eastbound stop and take the 38R toward downtown. Get off at Market & 1st and walk to the courtyard. The posted weekday headway is about six minutes. The budget includes walking and a short wait.",
    url: originDirections("transit"),
    sources: [routePage, farePage,
      link("SFMTA · inbound timetable", "https://www.sfmta.com/routes/schedule/38R?direction_id=1"),
      link("Google Maps · transit directions", originDirections("transit"))],
  },
  {
    id: "waymo", title: "Waymo", address: "Clement St & 14th Ave → 525 Market St",
    time: "08:00", minutes: 34, steps: 350, price: 30,
    payment: "Pay through Waymo with a linked card or Apple Pay.",
    notes: "Allow $30 for this example ride. Waymo quotes the fare and pickup point in the app before booking. Allow for the walk from its permitted drop-off to the courtyard.",
    url: originDirections("driving"),
    sources: [
      link("Waymo · San Francisco service", "https://waymo.com/rides/san-francisco/"),
      link("Waymo · trip pricing", "https://support.google.com/waymo/answer/9059184"),
      link("Waymo · payment options", "https://support.google.com/waymo/answer/14160746"),
      link("Google Maps · driving directions", originDirections("driving"))],
  },
  {
    id: "tesla", title: "Tesla supervised rideshare", address: "Clement St & 14th Ave → 525 Market St",
    time: "08:00", minutes: 35, steps: 350, price: 25,
    payment: "The rideshare app charges the designated payment method on your account.",
    notes: "Bay Area rideshare uses a safety driver. Allow $25 as a demo budget. Check the Tesla app for service at pickup, the wait and the fare before relying on this option.",
    url: originDirections("driving"),
    sources: [
      link("Tesla · Bay Area service with a safety driver", "https://assets-ir.tesla.com/tesla-contents/IR/TSLA-Q2-2026-Update.pdf"),
      link("Tesla · FSD (Supervised) rideshare terms", "https://www.tesla.com/legal/terms"),
      link("Google Maps · driving directions", originDirections("driving"))],
  },
  {
    id: "taxi", title: "City taxi", address: "Clement St & 14th Ave → 525 Market St",
    time: "08:00", minutes: 33, steps: 320, price: 25,
    payment: "Pay the driver with cash or a credit card. An e-hail app can charge a stored card.",
    notes: "A metered estimate for five miles and eight delayed minutes is $24.95 before tip. Budget $25. Distance and traffic affect the meter. Dispatch can arrange pickup in advance.",
    url: originDirections("driving"),
    sources: [
      link("SFMTA · taxi meter, dispatch and payment", "https://www.sfmta.com/getting-around/accessibility/taxi-ramp-taxi-services"),
      link("Google Maps · driving directions", originDirections("driving"))],
  },
];

export const nightlife = [
  {
    id: "afterhours", title: "Tech Afterhours SF", address: "BuzzWorks, 365 11th St",
    coords: [37.7713103, -122.4129017],
    time: "21:00", minutes: 75, steps: 3950, price: 0,
    notes: "For networking after dinner, this independent tech social has DJs, pool and time to talk, 9 PM–2 AM. The host lists no speaker program. To meet speakers from Cognee, Amplitude or Superlinked, catch their sessions at the daytime hackathon first. Free RSVP admits until full. The host lists a $20 guaranteed-entry option with AFTERS20. Bring valid ID, ages 21+.",
    url: fromLoft("365 11th Street"),
    sources: [
      link("Luma · Tech Afterhours SF, times and tickets", "https://luma.com/kkzbahld"),
      link("Daytime hackathon speakers", "https://luma.com/personalagenthack"),
      link("Google Maps · BuzzWorks", "https://www.google.com/maps/search/?api=1&query=BuzzWorks+San+Francisco&query_place_id=ChIJj3WmKSZ-j4ARlsHcAwSVu0I")],
  },
  {
    id: "game-night", title: "Totem Game Night", address: "Entrepreneurs First, 501 Folsom St",
    coords: [37.7869785, -122.39447],
    time: "19:50", minutes: 70, steps: 1050, price: 0,
    notes: "Meet founders and engineers over Catan or poker. The event runs 7–10 PM. The proposed arrival leaves time to walk from the hackathon. Food, drinks and entry are free with host approval. Check your RSVP before heading over.",
    url: fromLoft("501 Folsom Street"),
    sources: [
      link("Luma · game night, host and entry", "https://luma.com/zvwoxudt"),
      link("Google Maps · Entrepreneurs First", "https://www.google.com/maps/search/?api=1&query=Entrepreneurs+First+San+Francisco&query_place_id=ChIJ0SMYUgCBhYARquYKimp7nR8")],
  },
  {
    id: "westend", title: "Westend at 1015 Folsom", address: "1015 Folsom St",
    coords: [37.77805, -122.40568],
    time: "22:00", minutes: 90, steps: 2450, price: 37.36,
    notes: "Dance to Westend and TOBEHONEST in SoMa at 10 PM. The ticket page showed $31.25 and $37.36 tiers on Nov 20. Budget uses the higher tier before any checkout tax. Valid ID, ages 21+.",
    url: fromLoft("1015 Folsom Street"),
    sources: [
      link("1015 Folsom · event details", "https://1015.com/events/westend-2026-11-20/"),
      link("Eventim · venue ticket prices", "https://wl.eventim.us/event/westend/702480?afflky=1015Folsom"),
      link("Google Maps · 1015 Folsom", "https://www.google.com/maps/search/?api=1&query=1015+Folsom+St+San+Francisco")],
  },
];

export const weekend = [
  {
    date: "2026-11-21", time: "09:00", title: "Ferry Plaza Farmers Market", address: "Ferry Building, Embarcadero at Market St",
    notes: "Saturday market runs 8 AM–2 PM. Go in the morning to meet the farmers and pick out produce. The market is outdoors.",
    sources: [link("Foodwise · November holiday market hours", "https://foodwise.org/articles/foodwise-farmers-market-fall-feast-guide/")],
  },
  {
    date: "2026-11-21", time: "13:00", title: "Woodcarving with Nik Gelormino", address: "Museum of Craft and Design, 2569 Third St",
    notes: "An indoor, hands-on workshop from 1–3 PM. Tools and materials are included. General admission is $80. Check tickets before making the trip.",
    sources: [link("Museum of Craft and Design · workshop", "https://sfmcd.org/event-listing/nik-gelormino-workshop/")],
  },
  {
    date: "2026-11-22", time: "10:00", title: "Clement Street Farmers Market", address: "244 Clement St, Richmond District",
    notes: "Walk to the neighborhood market before lunch. The operator lists Sundays 9 AM–2 PM year-round, rain or shine.",
    sources: [link("Agricultural Institute of Marin · market directory", "https://www.agriculturalinstitute.org/farmers-markets")],
  },
  {
    date: "2026-11-22", time: "14:00", title: "SF AI Code & Coffee", address: "Salesforce Park, 425 Mission St",
    notes: "A weather-dependent outdoor gathering for local builders, tentatively 2–5 PM. Check the host update before leaving and bring a project to show.",
    sources: [link("Luma · SF AI Code & Coffee host updates", "https://luma.com/p9vzovjx")],
  },
];

export const weather = "San Francisco, Friday Nov 20. The National Weather Service expected a high near 57°F and an overnight low near 44°F. Its 2:59 PM PST hourly update gave a 0% chance of precipitation at 2, 3 and 4 AM Saturday near the Loft. Bring a layer. Rain was likely Saturday afternoon.";
export const weatherSources = [
  weatherPage,
  link("National Weather Service · hourly forecast near the Loft", "https://api.weather.gov/gridpoints/MTR/86,106/forecast/hourly"),
  link("Iowa Environmental Mesonet · archived NWS forecast", "https://mesonet.agron.iastate.edu/wx/afos/p.php?pil=ZFPMTR&e=202611202202"),
];
export const visitorTips = [
  "Visiting from Singapore? EZ-Link and SimplyGo are Singapore services. In San Francisco, use Clipper or a supported contactless bank card. Tap on when boarding Muni. BART requires tapping both in and out.",
  "For a late Mission District dinner, check the return service before leaving, pick an open, well-lit meeting point, and share that meeting place with your dinner companions.",
  "Keep a warm layer handy for the walk home. Friday evening temperatures fall toward the 40s.",
  "Carry physical photo ID for the AWS check-in. A phone photo or digital ID will not get you in.",
  "Tap the same Clipper card, bank card or phone on each Muni boarding. An adult fare covers 120 minutes on regular Muni.",
  "The 38R operates until about 10 PM on Fridays. Check the return trip in Maps before a late night out.",
  "Use the courtyard entrance at 525 Market. Pickups may be on a nearby side street.",
];
export const visitorSources = [
  link("Singapore LTA · fare cards and SimplyGo", "https://www.lta.gov.sg/content/ltagov/en/getting_around/public_transport/plan_your_journey.html"),
  link("SFMTA · riding and payment", "https://www.sfmta.com/getting-around/muni/how-ride-muni-quick-start-guide"),
];
