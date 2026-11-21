const venue = "525 Market St, San Francisco, CA";
const venueCoords = [37.79055, -122.39942];
const source = (label, url) => ({ label, url });

function directions(origin, destination, mode = "walking") {
  const params = new URLSearchParams({ api: "1", origin, destination, travelmode: mode });
  return "https://www.google.com/maps/dir/?" + params;
}

function placePhotos(name, address) {
  return source("Venue and photos on Google Maps",
    "https://www.google.com/maps/search/?" + new URLSearchParams({ api: "1", query: name + ", " + address }));
}

const boichikLocations = source("Boichik locations and hours", "https://boichikbagels.com/pages/locations");
const boichikDiets = source("Bagel ingredients and shared equipment", "https://boichikbagels.com/pages/faq");
const boichikGF = source("Gluten-free bagel ingredients", "https://boichikbagels.com/products/original-sunshine-gluten-free-everything-bagel");
const shopSeating = source("Owner’s description of the shops and seating", "https://www.sfgate.com/food/article/boichik-bagels-expanding-to-san-francisco-shops-18703166.php");
const properMenu = source("Proper Food’s San Francisco menu", "https://properfood.com/wp-content/uploads/2015/05/San-Francisco_Menu.pdf");
const properLocations = source("Proper Food locations and hours", "https://properfood.com/location/");
const eventAgenda = source("Organizer’s agenda", "https://luma.com/personalagenthack");
const sacramento = "3665 Sacramento St, San Francisco, CA";
const battery = "22 Battery St, San Francisco, CA";

const bagelDiet = "The standard plain bagel and Kite Hill almond spread have vegan ingredients. House bagels contain wheat. Boichik also lists a packaged vegan GF Everything made with gluten-free wheat starch and sesame. Staff warn that opening it in the shop exposes it to gluten. Ask about a sealed option and separate spread. Current stock is unknown.";

// These are per-person planning estimates. Travel starts at the breakfast venue,
// returns to the Loft for lunch and leaves the Loft after the evening program.
export const breakfast = [
  {
    id: "breakfast", title: "Boichik Bagels · Sacramento Street", address: sacramento,
    coords: [37.78736, -122.45299], time: "08:00", minutes: 20, price: 13, steps: 1100,
    notes: "The branch near the Richmond is in Presidio Heights. Doors open at 7:30am. The menu lists iced coffee for $3.75 and an oat milk swap. Order plain coffee to avoid the signature drink’s malt syrup. A back patio was reported at opening. Outlet availability and live wait are unknown. Leave by 8:20am for the 1 California, allowing 35–55 minutes to reach the Loft.",
    diet: bagelDiet, url: directions(sacramento, venue, "transit"),
    image: "https://boichikbagels.com/cdn/shop/files/sac_st_1024x1024.jpg?v=1712011676",
    imageCredit: "Sacramento Street shop · Boichik Bagels",
    sources: [boichikLocations, source("Sacramento Street coffee and bagel menu", "https://order.toasttab.com/online/boichik-bagels-sf-3665-sacramento-street"), boichikDiets, boichikGF, shopSeating, source("1 California route", "https://www.sfmta.com/routes/1-california"), placePhotos("Boichik Bagels", sacramento)],
  },
  {
    id: "breakfast-battery", title: "Boichik Bagels · Battery Street", address: battery,
    coords: [37.79175, -122.39958], time: "08:00", minutes: 20, price: 13, steps: 270,
    notes: "The Financial District shop opens at 6:30am. Hot and iced coffee are listed, with an oat milk option. Nearby Mechanics Monument Plaza has outdoor tables. Outlet availability, wait and stock are unknown. The Loft is a 2–5 minute walk. Call (415) 757-0375 about the packaged bagels.",
    diet: bagelDiet, url: directions(battery, venue),
    image: "https://boichikbagels.com/cdn/shop/files/outside_nice_1024x1024.jpg?v=1725821798",
    imageCredit: "Battery Street shop · Boichik Bagels",
    sources: [boichikLocations, source("Battery Street coffee and bagel menu", "https://order.toasttab.com/online/boichik-bagels-battery-street-22-battery-street"), boichikDiets, boichikGF, shopSeating, placePhotos("Boichik Bagels", battery)],
  },
  {
    id: "breakfast-proper", title: "Proper Food · Coconut chia pudding", address: venue,
    coords: venueCoords, time: "08:00", minutes: 15, price: 9, steps: 100,
    notes: "This street-level shop opens at 8am Friday in the hackathon building. Its SF menu lists coconut chia pudding for $7.25 and almond-milk overnight oats for $6.50. Counter stock and wait are unknown.",
    diet: "Both are labeled vegan and made with gluten-free ingredients. They contain almonds. The kitchen also handles gluten. Confirm cross-contact needs before ordering.",
    url: directions("Proper Food, " + venue, "AWS Builder Loft, " + venue),
    sources: [properMenu, properLocations, placePhotos("Proper Food", venue)],
  },
];

export const lunch = [
  {
    id: "lunch", title: "Proper Food · Lemon pepper tofu salad", address: venue,
    coords: venueCoords, time: "13:30", minutes: 25, price: 17, steps: 150,
    notes: "Downstairs at 525 Market. The Friday shop closes at 2:30pm. The $14.50 salad pairs tofu with rice, lentils, tomato and kale. Allow 5–10 minutes for pickup as a planning buffer. Current stock and queue are unknown.",
    diet: "Vegan and made with gluten-free ingredients. Contains soy and almonds. The kitchen also handles gluten.",
    url: directions("AWS Builder Loft, " + venue, "Proper Food, " + venue), sources: [properMenu, properLocations],
  },
  {
    id: "lunch-mixt", title: "MIXT · Build-your-own salad", address: "120 Sansome St, San Francisco, CA",
    coords: [37.79141, -122.40072], time: "13:30", minutes: 35, price: 20, steps: 650,
    notes: "A short walk across Market. Open until 3pm Friday, with indoor and outdoor seating. Allow 3–6 minutes each way. The counter queue and exact build-your-own price are unknown.",
    diet: "Request greens, beans, avocado and vegetables. Verify the dressing and any toppings for wheat, egg or dairy with the staff. Shared prep means cross-contact is possible.",
    url: directions(venue, "MIXT, 120 Sansome St, San Francisco, CA"),
    sources: [source("MIXT’s branch menu and hours", "https://www.mixt.com/locations/120-sansome/")],
  },
  {
    id: "lunch-mariposa", title: "Mariposa · Vegan Delight", address: "1 Ferry Building, Shop 32, San Francisco, CA",
    coords: [37.79549, -122.3937], time: "13:30", minutes: 45, price: 16, steps: 2300,
    notes: "Walk down Market to the waterfront. Allow 11–15 minutes each way and time to order at the counter. The $13.50 sandwich has cucumber, tomato, arugula and vegan cream cheese. The shop closes at 4pm Friday. Wait and stock are unknown.",
    diet: "Vegan, dairy-free and gluten-free on the café menu. The bakery is dedicated gluten-free. The spread contains nuts, and the facility also uses dairy and eggs.",
    url: directions(venue, "Mariposa Baking Company, Ferry Building, San Francisco, CA"),
    sources: [source("San Francisco café menu", "https://www.mariposabaking.com/pages/cafe-menu-sf"),
      source("Ferry Building bakeshop hours", "https://www.mariposabaking.com/pages/sf-bakeshop")],
  },
  {
    id: "lunch-host", title: "Hosted lunch · AWS Builder Loft", address: "525 Market St, 2nd floor, San Francisco, CA",
    coords: venueCoords, time: "13:30", minutes: 25, price: 0, steps: 0,
    notes: "The organizer says food is provided and schedules lunch at 1:30pm. Allow $0 additional spend for the hosted meal. The catering menu, stock and service time are unpublished.",
    diet: "Vegan, vegetarian, dairy-free and gluten-free portions are unconfirmed. Ask the caterer about ingredients and shared serving utensils before choosing this option.",
    url: "https://luma.com/personalagenthack", sources: [eventAgenda],
  },
];

export const dinner = [
  {
    id: "dinner", title: "Oren’s Hummus · Downtown", address: "71 3rd St, San Francisco, CA",
    coords: [37.78656, -122.40232], time: "19:45", minutes: 55, price: 25, steps: 910,
    notes: "Walk west on Market and turn onto 3rd. Allow about 7–10 minutes from the Loft. The dining room serves until 10pm Friday and takes reservations. The $17 veggie-skewer bowl includes turmeric rice, tomato, herbs and tahini. Seating and wait are unconfirmed.",
    diet: "The SF menu marks the rice bowl with veggie skewer vegan and gluten-free. It contains sesame. Choose the bowl without wheat pita and confirm handling if trace gluten or dairy matters.",
    payment: "Allow about $25 per person for the bowl, 5% restaurant surcharge, tax and tip.",
    reservable: true, url: directions(venue, "Oren's Hummus, 71 3rd St, San Francisco, CA"),
    sources: [source("SF dinner menu and surcharge", "https://orenshummus.com/lunch-dinner-menu-sf/"),
      source("SF hours and reservations", "https://orenshummus.com/locations/")],
  },
  {
    id: "dinner-lataqueria", title: "La Taqueria · Mission District", address: "2889 Mission St, San Francisco, CA",
    coords: [37.75085, -122.41824], time: "20:00", minutes: 40, price: 22, steps: 950,
    notes: "Take BART from Montgomery to 24th St/Mission, then walk south. Allow 20–35 minutes from the Loft. Michelin describes a counter-service queue. Live wait and group seating are unknown. The restaurant lists Friday closing as both 8:15pm and 8:45pm. Call (415) 285-7117 before leaving.",
    diet: "Chips with avocado and pico have been reported as a vegetarian choice. Ask about bean cooking fat or stock, corn tortillas, dairy and the shared griddle or fryer. Vegan and gluten-free suitability are unconfirmed.",
    payment: "Bring cash as a backup. Michelin lists cards accepted. Confirm mobile or contactless payment at the counter.",
    reservable: false, url: directions(venue, "La Taqueria, 2889 Mission St, San Francisco, CA", "transit"),
    sources: [source("Restaurant menu", "https://lataqueriasf.net/menu"), source("Restaurant hours and phone", "https://lataqueriasf.net/contact"),
      source("Alternate published Friday hours", "https://lataqueriasf.net/about"),
      source("Michelin’s counter-service and payment details", "https://guide.michelin.com/us/en/california/san-francisco/restaurant/la-taqueria"),
      source("San Francisco Chronicle’s dining visit", "https://www.sfchronicle.com/food/restaurant-review/article/la-taqueria-review-mission-burrito-san-francisco-22422092.php"),
      source("24th St/Mission station", "https://www.bart.gov/stations/24th")],
  },
  {
    id: "dinner-tacolicious", title: "Tacolicious · Mission", address: "741 Valencia St, San Francisco, CA",
    coords: [37.76104, -122.42144], time: "20:05", minutes: 65, price: 34, steps: 1400,
    notes: "Take BART to 16th St/Mission and walk to Valencia. Friday service runs until 11pm. Reserve through the restaurant’s OpenTable link. Availability and walk-in wait are unknown. Two tacos are $16, black beans $8. The menu lists a 6.5% surcharge.",
    diet: "The menu labels Verduras tacos and Black Midnight Beans vegan and gluten-free. Mushroom carnitas include cotija. Ask the kitchen about griddle and tortilla handling for strict restrictions.",
    payment: "The $34 estimate allows for food, surcharge, tax and tip. Drinks and transit are extra.",
    reservable: true, url: directions(venue, "Tacolicious, 741 Valencia St, San Francisco, CA", "transit"),
    sources: [source("Mission hours and reservations", "https://www.tacolicious.com/location/tacolicious-mission/"),
      source("Menu, dietary labels and pricing", "https://www.tacolicious.com/menus/")],
  },
  {
    id: "dinner-shizen", title: "Shizen · Vegan sushi", address: "370 14th St, San Francisco, CA",
    coords: [37.76822, -122.42176], time: "20:05", minutes: 75, price: 38, steps: 1400,
    notes: "Take BART to 16th St/Mission and walk north to 14th. Friday dinner ends at 9:30pm. Reservations are required for dining-room parties of up to four. The sushi bar takes limited walk-ins of up to three. No table or wait time has been confirmed.",
    diet: "Fully vegan, including the dairy-free sushi menu. Gluten-free dishes are individually marked, among them the $16 tomato and avocado ceviche and the $11 seaweed and cucumber salad. Ask about shared prep.",
    reservable: true, url: directions(venue, "Shizen, 370 14th St, San Francisco, CA", "transit"),
    sources: [source("Reservation policy and hours", "https://www.shizensf.com/"),
      source("Menu and gluten-free dishes", "https://www.shizensf.com/menu?menu=our-menu")],
  },
  {
    id: "dinner-california", title: "Chipotle · California Street", address: "50 California St, San Francisco, CA",
    coords: [37.79364, -122.39701], time: "19:45", minutes: 30, price: 17, steps: 660,
    notes: "A counter-service option about 5–7 minutes from the Loft. The California Street branch serves until 9pm Friday. The branch at 525 Market closes at 7pm. Walk-in wait and current counter prices are unknown.",
    diet: "Order a bowl with rice, black beans, fajita vegetables, fresh tomato salsa and guacamole. Chipotle lists these as vegan, with no gluten-containing ingredients. Skip the flour tortilla and dairy toppings. Request fresh gloves and clean utensils for cross-contact concerns.",
    reservable: false, url: directions(venue, "Chipotle, 50 California St, San Francisco, CA"),
    sources: [source("California Street hours", "https://locations.chipotle.com/ca/san-francisco/50-california-st"),
      source("525 Market hours", "https://locations.chipotle.com/ca/san-francisco/525-market-street"),
      source("Ingredient and allergen guide", "https://www.chipotle.com/content/chipotle/us/en/allergens.html")],
  },
];
