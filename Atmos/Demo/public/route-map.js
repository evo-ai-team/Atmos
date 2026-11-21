// Inbound 38R centerline between Geary/Park Presidio and Market/1st, projected
// from SFMTA's Muni Simple Routes (https://data.sf.gov/d/9exe-acju).
const gearyRapid = `M389.5,240.1 394.9,239.8 405.6,239.3 416.6,238.7 427.3,238 438.1,237.3 448.8,236.7 459.6,236.2 470.4,235.5 481.2,234.8 492,234.3 502.8,233.7 513.5,233 525,232.4 536.4,231.7 547.5,231.1 549.4,231 550.9,230.9 558.6,230.2 561.1,229.9 572.2,228.1 582.3,226.6 592.7,224.9 603,223.2 613.3,221.5 633.3,218.3 639.3,217.6 657.5,216.4 686.8,211.7 703.5,208.7 720.2,206.3 722.2,206.2 725.1,205.6 728.7,204.7 732,203.2 734.8,201.7 736.7,201.1 769.7,195.6 777.9,194.1 786.3,193 803.6,190.3 819.5,187.8 836,185.3 851.6,182.8 869.2,180.5 870.7,181.3 874.4,182.3 877.4,184.7 878.7,186.2 880,187.7 882.9,189.7 885.8,190.4 887.8,190.5 904.4,187.9 921,185.3 937.6,182.6 954.1,180 960,179 966.6,178 970.6,177.3 987.2,174.7 995.5,173.4 1003.8,172.1 1020.3,169.4 1023.9,168.9 1027.8,168.2 1036.9,166.8 1053.4,164.2 1064,162.5 1069,161.7 1071.7,162.7 1083.3,151.1 1088.6,145.4 1097.1,137.3 1104,130.4 1117.2,117.2 1123.1,111.5 1126.4,108.1`;

const modes = { muni: 'Muni', waymo: 'Waymo', tesla: 'Tesla Robotaxi', taxi: 'Taxi', walk: 'Walk' };
const mealNames = { breakfast: 'Boichik · Sacramento St', 'breakfast-battery': 'Boichik · Battery St', 'breakfast-proper': 'Proper Food' };
const radians = Math.PI / 180;
const mercator = lat => Math.asinh(Math.tan(lat * radians));

// The basemap and the overlays share a local Web Mercator coordinate system.
function point([lat, lon]) {
  const scale = 1400 / 0.139;
  return [Math.round((lon + 122.511) * scale * 10) / 10,
    Math.round((mercator(37.7995) - mercator(lat)) * scale / radians * 10) / 10];
}

function selected(data, slot) {
  const options = data.catalog[slot];
  return options.find(row => row.id === data.state.choices[slot]) || options.find(row => row.available !== false);
}

function routeLine(d, schematic = false) {
  return `<path d="${d}" fill="none" stroke="#ffffff" stroke-opacity=".86" stroke-width="5.3" vector-effect="non-scaling-stroke"/>
    <path d="${d}" fill="none" stroke="#406bad" stroke-width="${schematic ? 2.4 : 3.4}" ${schematic ? 'stroke-dasharray="3.5 5"' : ''} stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke"/>`;
}

function pin([x, y], kind) {
  return `<circle class="sf-pin" cx="${x}" cy="${y}" r="7.4" fill="${{home:'#fff',meal:'#bd642b',loft:'#284d85'}[kind]}" stroke="${kind === 'home' ? '#406bad' : '#fff'}" stroke-width="2" vector-effect="non-scaling-stroke"/>`;
}

function label([x, y], name, dx, dy, anchor = 'start', variant = '') {
  return `<text class="sf-pin-label ${variant}" x="${x + dx}" y="${y + dy}" text-anchor="${anchor}">${name}</text>`;
}

export function routeMap(data) {
  const mode = selected(data, 'transit')?.id;
  const meal = data.state.skippedSlots?.includes('breakfast') ? undefined : selected(data, 'breakfast');
  const home = point(data.catalog.originCoords);
  const loft = point(data.catalog.event.coords);
  const food = meal && point(meal.coords);
  const sameBuilding = meal?.id === 'breakfast-proper';
  const battery = meal?.id === 'breakfast-battery';
  const exactBus = mode === 'muni' && (!meal || sameBuilding || battery);
  const mealName = meal && (mealNames[meal.id] || 'Breakfast');
  const routeLabel = exactBus ? '38R Geary Rapid' : `${modes[mode] || 'Route'} · schematic`;
  const via = food && !sameBuilding ? [food, loft] : [loft];
  const route = exactBus
    ? routeLine(gearyRapid) + routeLine(`M${home} L389.5,240.1 M1126.4,108.1 L${via.join(' L')}`, true)
    : routeLine(`M${home} L${via.join(' L')}`, true);
  const desc = `${routeLabel} from the Richmond District${mealName ? ` via ${mealName}` : ''} to 525 Market Street. ${exactBus ? 'Solid blue shows the bus alignment. Dotted lines show approximate walking connections.' : 'Dotted lines connect the stops. See directions for streets and turns.'}`;

  // A width-fitted viewBox lets the geographic scene bleed above and below
  // the frame. The narrow-screen transform keeps both ends of the trip visible.
  return `<div class="basemap" style="background:#dce7e5;overflow:hidden">
    <style>
      .sf-map-scene {transform:translateY(-170px)}
      .sf-pin-label {font:700 16px system-ui,sans-serif;fill:#29496c;paint-order:stroke;stroke:#f8faf5;stroke-width:4.5;stroke-linejoin:round}
      .sf-route-tag,.sf-map-credit {position:absolute;pointer-events:none;color:#304d63;background:#fffffff0;line-height:1.3;font-family:system-ui,sans-serif}
      .sf-route-tag {bottom:30px;left:51%;transform:translateX(-50%);border:1px solid #c3d1dc;border-radius:12px;padding:3px 9px;font-size:11px;font-weight:650;white-space:nowrap}
      .sf-map-credit {bottom:2px;right:5px;border-radius:3px;padding:1px 4px;font-size:10px}
      @media (min-width:701px) and (max-width:1000px) {.sf-map-scene{transform:scale(1.14) translate(-95px,-119px)}.sf-pin-label{font-size:19px}.sf-home-label{transform:translateY(18px)}}
      @media (max-width:700px) {
        .sf-map-scene{transform:scale(1.5) translate(-265px,-132px)}.sf-pin-label{font-size:23px}.sf-pin{r:9px}
        .sf-route-tag{top:65px;bottom:auto;left:auto;right:12px;transform:none;font-size:10px;padding:2px 7px}.sf-map-credit{bottom:26px;font-size:9px}
        .sf-home-label{transform:translateY(24px)}.sf-sacramento-label{transform:translateY(38px)}
      }
      @media (max-width:450px) {.sf-map-scene{transform:scale(1.5) translate(-265px,-36px)}.sf-pin-label{font-size:27px}.sf-home-label{transform:none}}
      @media (min-width:451px) and (max-width:580px) {.sf-map-scene{transform:scale(1.5) translate(-265px,-89px)}}
      @media (max-width:360px) {.map-stage{height:295px}.sf-map-scene{transform:scale(1.5) translate(-265px,-12px)}.sf-route-tag{top:auto;bottom:42px}.sf-battery-label{transform:translateY(21px)}}
    </style>
    <svg role="img" aria-label="${desc}" width="100%" height="100%" viewBox="0 -1 1400 2" preserveAspectRatio="xMidYMid meet" style="display:block;overflow:visible">
      <g class="sf-map-scene" font-family="system-ui,sans-serif">
        <image href="/assets/sf-route-map.svg" x="0" y="-285" width="1400" height="850"/>
        ${route}
        ${pin(home, 'home')}${label(home, 'Richmond', 14, -7, 'start', 'sf-home-label')}
        ${food && !sameBuilding ? pin(food, 'meal') + label(food, mealName, battery ? -13 : 12, battery ? -13 : -10, battery ? 'end' : 'start', battery ? 'sf-battery-label' : 'sf-sacramento-label') : ''}
        ${pin(loft, 'loft')}${label(loft, '525 Market St', -13, battery ? 37 : -12, 'end')}
        ${sameBuilding ? label(loft, 'Proper Food', -13, 25, 'end') : ''}
      </g>
    </svg><span class="sf-route-tag" aria-hidden="true">${routeLabel}</span><span class="sf-map-credit">© OpenStreetMap contributors · OpenFreeMap · OpenMapTiles</span>
  </div>`;
}
