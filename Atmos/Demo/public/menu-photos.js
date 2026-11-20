function photo(file, label, source) {
  return { src: `/assets/menu/${file}.webp`, label, source };
}

const sunshine = "https://www.originalsunshine.com/how-to-original-sunshine";
const boichik = [
  photo("sunshine-plain-bagel", "Gluten-free plain bagel", sunshine),
  photo("sunshine-everything-bagel", "Gluten-free everything bagel", sunshine),
  photo("boichik-iced-coffee", "Black iced coffee", "https://boichikbagels.com/products/iced-coffee-pickup-only"),
  photo("boichik-bagels-and-spreads", "Assorted bagels and spreads", "https://boichikbagels.com/cdn/shop/collections/awesome_spread_400x.jpg?v=1604871825"),
  photo("boichik-bialy", "Boichik’s bialy", "https://boichikbagels.com/cdn/shop/products/bialy_400x.jpg?v=1603288061")
];
const mixt = "https://www.mixt.com/locations/120-sansome/";
const laTaqueria = "https://lataqueriasf.net/";
const shizen = "https://www.shizensf.com/";
const chipotle = "https://locations.chipotle.com/ca/san-francisco/50-california-st";

// These photographs illustrate the venue's menu. Dietary details belong to each recommended order.
export const menuPhotos = {
  breakfast: boichik,
  "breakfast-battery": boichik,
  "breakfast-proper": [
    photo("proper-breakfast-trays", "Proper Food breakfast trays", "https://properfood.com/wp-content/uploads/2015/05/Breakfast-1.jpg"),
    photo("proper-salmon-toast", "Salmon toast", "https://properfood.com/wp-content/uploads/2015/05/Breakfast_Category_Images_updated@1x.jpg")
  ],
  lunch: [
    photo("proper-beet-salad", "Beet salad", "https://properfood.com/wp-content/uploads/2015/05/PF_Featured_BeetSalad.jpg"),
    photo("proper-lunch-boxes", "Boxed lunch selection", "https://properfood.com/wp-content/uploads/2018/07/home_hero_NEW@2x.jpg"),
    photo("proper-seasonal-menu", "Seasonal salads and bowls", "https://properfood.com/")
  ],
  "lunch-mixt": [
    photo("mixt-design-your-own", "Design Your Own salad", mixt),
    photo("mixt-beetnik", "Beetnik salad", mixt),
    photo("mixt-mediterranean-bowl", "Mediterranean bowl", mixt)
  ],
  "lunch-mariposa": [
    photo("mariposa-empanada", "Mariposa’s empanada", "https://www.mariposabaking.com/products/empanada"),
    photo("mariposa-sandwich-rolls", "Gluten-free sandwich rolls", "https://www.mariposabaking.com/products/sandwich-rolls")
  ],
  "lunch-host": [],
  dinner: [
    photo("orens-hummus-and-pita", "Hummus with pita", "https://orenshummus.com/lunch-dinner-menu-sf/"),
    photo("orens-jazz-box", "Jazz Box with hummus and sides", "https://orenshummus.com/wp-content/uploads/2023/08/Orens-Hummus-Jazz-Box-1.jpg"),
    photo("orens-matzo-brittle", "Matzo brittle dessert", "https://orenshummus.com/wp-content/uploads/2024/02/orens-hummus-matzo-brittle.jpg")
  ],
  "dinner-lataqueria": [
    photo("la-taqueria-burrito", "Mission-style burrito", laTaqueria),
    photo("la-taqueria-chips", "Chips and serranos", laTaqueria)
  ],
  "dinner-tacolicious": [
    photo("tacolicious-table", "Tacos and salad at Tacolicious", "https://www.tacolicious.com/menus/")
  ],
  "dinner-shizen": [
    photo("shizen-specialty-roll", "Vegan specialty roll", shizen),
    photo("shizen-ramen", "Vegan ramen", shizen),
    photo("shizen-nigiri", "Vegetable nigiri", shizen)
  ],
  "dinner-california": [
    photo("chipotle-burrito-bowl", "Burrito bowl", chipotle),
    photo("chipotle-quesadilla", "Quesadilla and sides", chipotle),
    photo("chipotle-burrito", "Burrito", chipotle)
  ]
};
