import { shapes } from './route-shapes.js';
import { esc } from './views.js';

const modes = {
  muni: {name:'Muni', color:'#315da0'}, walk: {name:'Walk', color:'#247453'},
  waymo: {name:'Waymo', color:'#176884', drive:0}, tesla: {name:'Tesla', color:'#ad4239', drive:1},
  taxi: {name:'Taxi', color:'#8c620e', drive:2},
};
const legNames = {transit:'Morning route', toDinner:'Travel to dinner', toNightlife:'Travel to nightlife'};
export const isTravelSlot = slot => Object.hasOwn(legNames,slot);

const radians = Math.PI / 180;
const mercator = lat => Math.asinh(Math.tan(lat * radians));
function project([lat,lon]) {
  const scale = 1400 / 0.139;
  return [(lon+122.511)*scale, (mercator(37.7995)-mercator(lat))*scale/radians];
}

function selected(data,slot,id = data.state.choices[slot]) {
  const options = data.catalog[slot];
  return options.find(o=>o.id===id && o.available!==false) || options.find(o=>o.available!==false);
}

function stop(key, label, coords) { return {key,label,coords,point:project(coords)}; }
function venue(item) { return stop(item.id,item.title.split(' · ')[0],item.coords); }

function appendLeg(segments, from, to, mode) {
  const shape = shapes[from.key+'/'+to.key];
  const add = (kind,encoded) => {
    const points = encoded.split(' ').map(pair=>pair.split(',').map(Number));
    segments.push({kind,points});
  };
  if (!shape) {
    segments.push({kind:'connection',points:[from.point,to.point]});
  } else if (mode==='muni') {
    add('connection',shape.muni.access);
    add(mode,shape.muni.ride);
    add('connection',shape.muni.exit);
    return shape.muni.line;
  } else if (mode==='walk') {
    add(mode,shape.walk);
  } else {
    add(mode,shape.drive[modes[mode].drive % shape.drive.length]);
  }
}

// A preview selects the displayed mode only. Confirmed choices and tracker
// defaults supply the route whenever the option menu is open.
export function routeFor(data, requestedSlot='transit', previewId) {
  const slot = requestedSlot==='toDinner' && !data.catalog.toDinner?.length ? 'toNightlife' : requestedSlot;
  const saved = data.state.choices[slot] || data.tracker.legs?.find(leg=>leg.slot===slot)?.id;
  const option = selected(data,slot,slot===requestedSlot ? previewId ?? saved : saved);
  const mode = option.id;
  const loft = stop('loft','525 Market St',data.catalog.event.coords);
  const stops = [];
  const segments = [];
  const lines = new Set();
  const connect = (from,to,id) => {
    const line = appendLeg(segments,from,to,id);
    if (line) lines.add(line);
  };
  if (slot==='transit') {
    const home = stop('home','Richmond',data.catalog.originCoords);
    const meal = !data.state.skippedSlots?.includes('breakfast') && selected(data,'breakfast');
    stops.push(home);
    if (meal && meal.id!=='breakfast-proper') {
      const food = stop(meal.id,meal.title.replace('Boichik Bagels','Boichik'),meal.coords);
      stops.push(food);
      connect(home,food,mode);
      connect(food,loft,meal.id==='breakfast-battery' ? 'walk' : mode);
    } else {
      if (meal) loft.label = 'Proper Food · 525 Market St';
      connect(home,loft,mode);
    }
    stops.push(loft);
  } else {
    const dinner = !data.state.skippedSlots?.includes('dinner') && selected(data,'dinner');
    const from = slot==='toDinner' || !dinner ? loft : venue(dinner);
    const to = venue(slot==='toDinner' ? dinner : selected(data,'nightlife'));
    stops.push(from,to);
    connect(from,to,mode);
  }
  const lineNames = [...lines].map(n=>({'1':'1 California','38R':'38R Geary Rapid'}[n] || n));
  const modeLabel = lineNames.length ? 'Muni · '+lineNames.join(' / ') :
    modes[mode].name+(modes[mode].drive!==undefined ? ' · example drive' : '');
  return {slot,option,mode,modeLabel,title:legNames[slot],stops,segments};
}

export function routeMap(route, width, height, hero=false) {
  const {segments,stops,modeLabel} = route;
  const points = segments.flatMap(s=>s.points);
  const xs = points.map(p=>p[0]), ys = points.map(p=>p[1]);
  const minX=Math.min(...xs), maxX=Math.max(...xs), minY=Math.min(...ys), maxY=Math.max(...ys);
  // Leave space for the location card above the route on mobile and beside it on desktop.
  const left=hero && width>700 ? Math.min(315,width*0.29) : 25;
  const right=hero && width>700 ? 84 : 25;
  const top=hero && width<=700 ? 127 : 24;
  const bottom=hero ? 43 : 34;
  const scale=Math.min(4.4,(width-left-right)/Math.max(1,maxX-minX),(height-top-bottom)/Math.max(1,maxY-minY));
  const tx=(width+left-right-scale*(minX+maxX))/2;
  const ty=(height+top-bottom-scale*(minY+maxY))/2;
  const screen=([x,y])=>[+(tx+x*scale).toFixed(1),+(ty+y*scale).toFixed(1)];
  const path=pts=>'M'+pts.map(p=>screen(p).join(',')).join(' L');
  const paths=segments.map(({kind,points})=>{
    const d=path(points);
    const walk=kind==='walk' || kind==='connection';
    const color=kind==='connection' ? '#566b7d' : modes[kind].color;
    return `<path d="${d}" stroke="#ffffff" stroke-opacity=".9" stroke-width="6"/>
      <path data-route-mode="${kind}" d="${d}" stroke="${color}" stroke-width="${walk ? 2.7 : 3.6}" ${walk ? 'stroke-dasharray="3 5"' : ''}/>`;
  }).join('');
  const end=screen(stops.at(-1).point);
  const nearEnd=stops.length===3 && Math.hypot(...screen(stops[1].point).map((v,i)=>v-end[i]))<110;
  const pins=stops.map((s,i)=>{
    const [x,y]=screen(s.point);
    const anchor=x < width/2 ? 'start' : 'end';
    const dy=(i===0 && stops.length===2 || i===stops.length-1 && nearEnd) ? 17 : -10;
    return `<circle cx="${x}" cy="${y}" r="5.5" fill="${i===0?'#fff':i===stops.length-1?'#294a78':'#ad5825'}" stroke="${i===0?'#365779':'#fff'}" stroke-width="2"/>
      <text class="sf-pin-label" x="${x+(anchor==='start'?8:-8)}" y="${y+dy}" text-anchor="${anchor}">${esc(s.label)}</text>`;
  }).join('');
  const desc=route.title+' · '+modeLabel+' · '+stops.map(s=>s.label).join(' → ');
  return `<svg role="img" aria-label="${esc(desc)}" viewBox="0 0 ${width} ${height}" width="100%" height="100%">
    <g transform="translate(${tx} ${ty}) scale(${scale})" aria-hidden="true">
      <image href="/assets/sf-mission-streets.svg" x="690" y="550" width="560" height="155"/>
      <image href="/assets/sf-route-map.svg" x="0" y="-285" width="1400" height="850"/>
    </g><g fill="none" stroke-linecap="round" stroke-linejoin="round">${paths}</g>${pins}
    <path data-replay-path d="${path(points)}" fill="none" stroke="none"/>
    <circle data-gps-marker visibility="hidden" r="6" fill="#b33924" stroke="#fff" stroke-width="2"/>
    </svg><span class="sf-route-tag">${esc(modeLabel)}</span>
    ${hero ? '<span class="sf-map-credit">© OpenStreetMap · OpenFreeMap · OpenMapTiles · DataSF</span>' : ''}`;
}
