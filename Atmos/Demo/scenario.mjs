import { createHash } from 'node:crypto';
import { event, transit as rideModes, transitForBreakfast, nightlife, weekend, visitorTips, visitorSources, weather, weatherSources, origin, originCoords } from './city.mjs';
import { breakfast, lunch, dinner } from './food.mjs';

export const intro = "Hey Atmos, I'm visiting Richmond SF for the first time from Singapore for work, and I signed up for a hackathon at the AWS building. I've told my boss I'm sick today because I really wanted to attend this event and meet cool people. I'm here until Sunday and want to explore the best food and entertainment this city has to offer. Can you plan my itinerary for me?";
const heroImage = '/assets/san-francisco.jpg';
const contacts = [
  { id: 'gio', name: 'Gio L.', platform: 'Instagram story', caption: 'First stop in SF 🌉 Anyone around for dinner?', place: 'Golden Gate Bridge', image: heroImage },
  { id: 'andrew', name: 'Andrew S.', platform: 'X post', caption: 'In San Francisco for the Systems Forum. Free once the last session wraps!', place: 'SF Systems Forum', image: '/assets/forum.jpg' },
];
const loft = { title:'AWS Builder Loft', address:event.address, coords:event.coords ?? [37.7906, -122.3992] };
const home = { title:'Richmond pickup', address:'Clement St & 14th Ave, San Francisco, CA', coords:originCoords };
const transit = [...rideModes,walkingOption(home,loft)];
// The image and its transcription are paired test fixtures. Match the visible
// business name and street to the demo gazetteer, independent of who is pictured.
const teamPost = { caption: 'Dinner with the team! :)', observedSigns: ['FERRY LANE KITCHEN', 'MARKET ST'] };
const demoVenues = [{ title: 'Ferry Lane Kitchen', street: 'Market St', coords: [37.7900, -122.4001] }];
const teamVenue = demoVenues.find(v => [v.title, v.street].every(s => teamPost.observedSigns.includes(s.toUpperCase())));
const alert = {
  title: 'Your boss just posted on X', caption: teamPost.caption, place: teamVenue.title, image: '/assets/team-dinner.jpg',
  notes: `The sign reads “${teamVenue.title}” and the street sign reads “${teamVenue.street}”. This fictional venue is about ${Math.round(km(loft, teamVenue) * 1000 / 25) * 25} m from the Loft. You can switch dinner to another neighborhood.`,
};
export const catalog = { date: '2026-11-20', heroImage, heroCredit: { label: 'Rich Niewiroski Jr. · CC BY 2.5', url: 'https://commons.wikimedia.org/wiki/File:GoldenGateBridge-001.jpg' }, origin, originCoords, event, transit, breakfast, lunch, dinner, nightlife, weekend, contacts, visitorTips, visitorSources, weather, weatherSources, alert };
export const catalogRevision = createHash('sha256').update(JSON.stringify(catalog)).digest('hex');
const meals = ['breakfast','lunch','dinner'];
const slots = ['transit',...meals,'nightlife'];
const eveningSlots = ['toDinner','toNightlife'];
function choiceById(guide,slot,id) {
  if (slot === 'event') return id === guide.event.id ? guide.event : undefined;
  return guide[slot]?.find(option => option.id === id);
}
export const defaultProfile = { diet: 'Vegan, dairy-free, gluten-free', walkingGoal: 2000, budget: 400, socialStatus: 'Socialize', habits: 'Coffee and breakfast around 8 AM. Likes an evening drink.' };
export function searchLocalMemory(guide, state, scope, query) {
  const facts = scope === 'private'
    ? [...Object.entries(state.profile).filter(([,v])=>typeof v !== 'boolean').map(([k,v]) => `${k}: ${v}`),
      ...Object.entries(state.choices).filter(([slot])=>slot !== 'toDinner' || !state.skippedSlots?.includes('dinner')).map(([slot,id]) => state.skippedSlots?.includes(slot)
        ? `${slot}: skipped for this visit`
        : `${{toDinner:'Travel to dinner',toNightlife:'Travel to nightlife'}[slot] ?? slot}: ${choiceById(guide,slot,id)?.title ?? ''}`)]
    : [guide.event,...guide.transit,...guide.breakfast,...guide.lunch,...guide.dinner,...guide.nightlife,...guide.weekend]
      .map(o=>[o.title,o.address,o.notes,o.diet,o.sources?.[0]?.url].filter(Boolean).join(' · ')).concat(guide.weather,guide.visitorTips);
  const ignored = new Set(['what','which','where','when','would','could','should','about','that','the','and','for','are','was','can','does','will','you','how','tell']);
  const aliases = { money:'budget', spending:'budget', spend:'budget', food:'diet', gluten:'gluten', meet:'social', steps:'walking', schedule:'time' };
  const tokens = [...new Set(query.toLowerCase().match(/[\p{L}\d]+/gu) ?? [])].filter(t=>t.length>2 && !ignored.has(t));
  const terms = [...new Set(tokens.flatMap(t => aliases[t] ? [t,aliases[t]] : [t]))];
  const ranked = facts.map(fact=>({fact,score:terms.filter(t=>fact.toLowerCase().includes(t)).length})).filter(x=>x.score>0);
  return ranked.sort((a,b)=>b.score-a.score).slice(0,5).map(x=>x.fact);
}
export function newState() {
  return { started: false, revision: 0, profile: { ...defaultProfile }, choices: {}, confirmedSlots: [], skippedSlots: [], invitations: [], reservation: null, expenses: [], alert: 'idle' };
}
export class InputError extends Error {}

function profileFrom(text) {
  const profile = { ...defaultProfile };
  const details = [];
  if (/richmond/i.test(text)) details.push('Staying in the Richmond District, San Francisco');
  if (/singapore/i.test(text)) details.push('Visiting from Singapore');
  if (/first time/i.test(text)) details.push('First visit');
  if (/\bwork\b|business trip/i.test(text)) details.push('Traveling for work');
  if (/aws|hackathon/i.test(text)) details.push('Registered for the AWS Loft hackathon');
  if (/sunday/i.test(text)) details.push('In town through Sunday');
  if (/meet|socializ|network/i.test(text)) details.push('Wants to meet people');
  if (/food|entertainment/i.test(text)) details.push('Interested in local food and entertainment');
  profile.trip = details.join(' · ');
  profile.discretion = /\bboss\b/i.test(text) && /\bsick\b/i.test(text);
  if (profile.discretion) profile.workplaceNote = 'Told boss they were sick today. Offer a discreet dinner alternative.';
  const budget = text.match(/(?:under|less than|budget(?: of)?|spend up to)\s*\$(\d+(?:\.\d{1,2})?)/i);
  if (budget && Number(budget[1]) > 0) profile.budget = Number(budget[1]);
  const steps = text.match(/\b(\d[\d,]*(?:\.\d+)?)\s*(k)?\s*steps\b/i);
  if (steps && Number(steps[1].replaceAll(',', '')) > 0) profile.walkingGoal = Math.round(Number(steps[1].replaceAll(',', '')) * (steps[2] ? 1000 : 1));
  return profile;
}
function selected(s, slot) {
  if (s.skippedSlots?.includes(slot)) return undefined;
  return choiceById(catalog,slot,s.choices[slot]);
}
function alternateDinner(s) {
  const candidates = dinner.filter(o => o.available !== false && o.id !== s.choices.dinner && km(o, teamVenue) > 1);
  return candidates.sort((a,b) => Number(!!b.reservable) - Number(!!a.reservable) || km(b,teamVenue) - km(a,teamVenue))[0];
}

export function guideForVisit(guide,s,evidence) {
  const alternate = alternateDinner(s);
  const morning = selected(s,'breakfast');
  const routePlan = eveningPlan(s);
  const eveningOrigin = selected(s,'dinner') ?? loft;
  const first = morning ?? loft;
  const firstTime = morning ? minutes(morning.time) : 555;
  const departures = transitForBreakfast(guide.transit,morning).map(base=>{
    const option = base.id === 'walk' ? walkingOption(home,first) : base;
    const path = modeRoute(home,first,base.id);
    const sources = option.sources.filter(source=>!source.url.includes('google.com/maps/dir'));
    const fareNote = path.mode === 'driving'
      ? ` The demo budgets $${option.price} for this ride. If another ride is needed after breakfast, the tracker adds the same allowance for that leg.` : '';
    return {...option,...path,time:clock(firstTime-path.minutes),arrivesAt:clock(firstTime),
      origin:home.address,destination:first.address,originName:home.title,destinationName:first.title,
      notes:option.notes+fareNote,
      sources:[...sources,{label:'Google Maps · directions from public pickup',url:path.url}]};
  });
  return {
    ...guide,
    transit:departures,
    toDinner:routePlan.toDinner?.options ?? [],
    toNightlife:routePlan.toNightlife?.options ?? [],
    weather:evidence?.weather ?? guide.weather,
    alert:{...guide.alert,alternative:alternate && `${alternate.title} at ${alternate.address}. ${alternate.diet}`},
    nightlife:guide.nightlife.map(night=>({
      ...night,url:route(eveningOrigin,night,travelMode(s.choices.toNightlife ?? automaticMode(eveningOrigin,night))).url,
    })),
  };
}
function changeDinner(s, id) {
  if (s.choices.dinner !== id) { s.invitations = []; s.reservation = null; }
  s.choices.dinner = id;
}
function confirm(s,slot) {
  s.skippedSlots = s.skippedSlots.filter(item => item !== slot);
  if (!s.confirmedSlots.includes(slot)) s.confirmedSlots.push(slot);
}
export function updateState(previous, input) {
  if (!input || typeof input !== 'object') throw new InputError('Choose a demo action.');
  const s = structuredClone(previous);
  s.confirmedSlots ??= [];
  s.skippedSlots ??= [];
  if (input.action === 'reset') return { ...newState(), revision: s.revision + 1 };
  if (input.action === 'begin') {
    s.started = true;
  } else if (input.action === 'start') {
    if (typeof input.transcript !== 'string' || !input.transcript.trim() || input.transcript.length > 6000) throw new InputError('Enter a trip briefing of up to 6,000 characters.');
    if (!/hackathon|richmond|san francisco|\bsf\b/i.test(input.transcript)) throw new InputError('This test itinerary covers the San Francisco hackathon. Use the sample briefing or mention that trip.');
    s.started = true;
    s.profile = profileFrom(input.transcript);
    if (!s.profile.discretion) s.alert = 'idle';
  } else {
    if (!s.started) throw new InputError('Start your trip briefing first.');
    switch (input.action) {
      case 'previewNightlife': {
        const option = choiceById(catalog,'nightlife',input.id);
        if (!option || option.available === false) throw new InputError('This nightlife option is unavailable.');
        if (option.id !== 'afterhours' || !s.profile.discretion || s.alert === 'shown') return s;
        s.alert = 'shown';
        break;
      }
      case 'choose': {
        const evening = eveningSlots.includes(input.slot);
        if (input.slot !== 'event' && !slots.includes(input.slot) && !evening) throw new InputError('Unknown itinerary segment.');
        const o = evening ? eveningPlan(s)[input.slot]?.options.find(option => option.id === input.id)
          : choiceById(catalog,input.slot,input.id);
        if (!o || o.available === false) throw new InputError('This option is unavailable.');
        if (input.slot === 'dinner') changeDinner(s, o.id);
        else s.choices[input.slot] = o.id;
        confirm(s,input.slot);
        // Direct confirmation also works for clients that never preview the tile.
        if (input.slot === 'nightlife' && o.id === 'afterhours' && s.profile.discretion && s.alert === 'idle') s.alert = 'shown';
        break;
      }
      case 'skip': {
        if (!meals.includes(input.slot)) throw new InputError('Choose breakfast, lunch or dinner to skip.');
        if (s.skippedSlots.includes(input.slot)) return s;
        s.skippedSlots.push(input.slot);
        s.confirmedSlots = s.confirmedSlots.filter(slot => slot !== input.slot);
        if (input.slot === 'dinner') {
          s.invitations = [];
          s.reservation = null;
        }
        break;
      }
      case 'invite':
        if (!contacts.some(c => c.id === input.id) || s.profile.socialStatus !== 'Socialize' || !s.confirmedSlots.includes('dinner') || !selected(s,'dinner')) throw new InputError('Confirm a dinner venue before drafting an invitation.');
        if (!s.invitations.includes(input.id)) s.invitations.push(input.id);
        break;
      case 'reserve':
        if (!s.confirmedSlots.includes('dinner') || !selected(s,'dinner')?.reservable) throw new InputError('Confirm a restaurant that accepts reservations.');
        s.reservation = s.choices.dinner;
        break;
      case 'expense': {
        if (typeof input.label !== 'string' || !input.label.trim() || input.label.length > 100 ||
            typeof input.amount !== 'number' || !Number.isFinite(input.amount) || input.amount <= 0 || input.amount > 10000) throw new InputError('Enter an expense label and a positive dollar amount up to $10,000.');
        s.expenses ??= [];
        if (s.expenses.length >= 300) throw new InputError('The expense log is full for this demo.');
        s.expenses.push({label:input.label.trim(),amount:Math.round(input.amount*100)/100});
        break;
      }
      case 'alert':
        if (!s.profile.discretion) throw new InputError('This briefing has no workplace conflict.');
        s.alert = 'shown'; break;
      case 'dismiss': if (s.alert === 'shown') s.alert = 'dismissed'; break;
      case 'reroute': {
        if (s.alert !== 'shown') throw new InputError('Open the notification before rerouting.');
        const alternate = alternateDinner(s);
        if (!alternate) throw new InputError('There is no other verified dinner option away from the venue.');
        changeDinner(s, alternate.id);
        confirm(s,'dinner');
        s.alert = 'rerouted'; break;
      }
      default: throw new InputError('Unknown demo action.');
    }
  }
  s.revision++;
  return s;
}

function km(a,b) {
  const [ay,ax] = a.coords, [by,bx] = b.coords;
  return Math.hypot((ay-by)*111.1,(ax-bx)*87.8);
}
const clock = m => [Math.floor(m / 60) % 24, Math.round(m % 60)].map(n => String(n).padStart(2,'0')).join(':');
function minutes(time) { const [h,m] = time.split(':').map(Number); return h*60+m; }
function route(a,b,mode) {
  const distance = km(a,b) * 1.3; // Grid-distance estimate, not a live route.
  const walk = mode === 'walking', bus = mode === 'transit';
  const walkingKm = walk ? distance : Math.min(distance, bus ? 0.55 : 0.10);
  const duration = distance < 0.06 ? 0 : Math.ceil(walk ? distance*13 : bus ? 9+distance*4.2 : 5+distance*2.8);
  const url = new URL('https://www.google.com/maps/dir/');
  url.search = new URLSearchParams({api:'1',origin:a.address,destination:b.address,travelmode:mode}).toString();
  return { minutes:duration, steps:Math.round(walkingKm*1350), distanceKm:Math.round(distance*100)/100, url:url.href, mode };
}
function travelMode(id) {
  if (id === 'walk') return 'walking';
  return id === 'muni' ? 'transit' : 'driving';
}
function automaticMode(from,to) { return km(from,to)>1.6 ? 'muni' : 'walk'; }
function pickupAllowance(id) { return id === 'waymo' ? 10 : 15; }
function modeRoute(from,to,id) {
  const path = route(from,to,travelMode(id));
  if (path.mode === 'driving' && path.minutes) path.minutes += pickupAllowance(id)-5;
  return path;
}

function walkingOption(from,to) {
  const path = route(from,to,'walking');
  return {
    ...path,id:'walk',title:'Walk',price:0,origin:from.address,destination:to.address,
    originName:from.title,destinationName:to.title,address:from.address+' → '+to.address,
    wait:'No pickup wait', waitNote:'Leave when you are ready.', payment:'Free.',
    notes:`Walk from ${from.title} to ${to.title}. Allow about ${path.minutes} minutes over an estimated ${path.distanceKm.toFixed(1)} km. Check Maps for crossings and accessible paths.`,
    sources:[{label:'Google Maps · walking directions',url:path.url}]
  };
}

function eveningLeg(slot,from,to,departure,lastFare,chosenId) {
  const walk = walkingOption(from,to);
  const options = [walk,...rideModes.filter(mode=>mode.available!==false).map(provider=>{
    const muni = provider.id === 'muni';
    const path = modeRoute(from,to,provider.id);
    const pickup = pickupAllowance(provider.id);
    const transfer = departure-lastFare <= 120;
    // These are comparison allowances for a short city ride, never provider fare quotes.
    const base = provider.id === 'waymo' ? 8 : 6;
    const perKm = provider.id === 'waymo' ? 2.60 : 2.25;
    const price = muni ? (transfer ? 0 : provider.price) : Math.round((base+path.distanceKm*perKm)*100)/100;
    const name = muni ? 'Muni' : provider.title;
    const note = muni ? `The estimate assumes Muni service${transfer ? ' within the prior fare’s 120-minute transfer window' : ''}. Choose a Muni itinerary in Maps; regional services can have a separate fare.`
      : `For this demo allow $${base} plus $${perKm.toFixed(2)} per km. Check with the provider for actual pickup availability and fare.`;
    const sources = provider.sources.filter(source => !source.url.includes('maps') && (!muni || source.url.includes('/fares')));
    return {
      ...path,id:provider.id,title:name,price,origin:from.address,destination:to.address,
      originName:from.title,destinationName:to.title,address:walk.address,
      wait:muni ? 'Allow 9 min for boarding' : `Allow ${pickup} min for pickup`,
      waitNote:'Planning allowance for this evening leg. Check the current departure or pickup estimate.',
      payment:provider.payment,
      notes:`${name} from ${from.title} to ${to.title}. About ${path.distanceKm.toFixed(1)} km. ${note}`,
      sources:[...sources,{label:'Google Maps · directions for this leg',url:path.url}]
    };
  })].map(option=>{
    const arrival = departure+option.minutes;
    // The Totem host lists a 10 PM close. A long travel choice can miss the event.
    let timingNote = to.id === 'game-night' && arrival >= 22*60
      ? 'Arrival is at or after Totem’s 10 PM closing time. Choose an earlier route or another event.'
      : undefined;
    if (to.id === 'dinner-lataqueria' && arrival >= 20*60+15) {
      timingNote = arrival >= 20*60+45
        ? 'Arrival is at or after both published Friday closing times for La Taqueria. Pick a faster route or another dinner venue.'
        : 'Arrival falls between La Taqueria’s conflicting 8:15 and 8:45 PM closing times. Call the restaurant before leaving.';
    }
    return {...option,slot,time:clock(departure),arrivesAt:clock(arrival),calories:Math.round(option.steps*0.04),
      ...(timingNote && {timingNote,notes:option.notes+' '+timingNote})};
  });
  return {options,current:options.find(o=>o.id===chosenId)};
}

function eveningPlan(s) {
  const pm = selected(s,'dinner');
  const night = selected(s,'nightlife');
  const programEnds = minutes(event.ends);
  const toDinner = pm ? eveningLeg('toDinner',loft,pm,programEnds,-Infinity,s.choices.toDinner) : null;
  const depart = pm ? (toDinner.current ? minutes(toDinner.current.arrivesAt) : minutes(pm.time))+(pm.minutes ?? 60) : programEnds;
  const lastFare = toDinner?.current?.id === 'muni' ? programEnds : -Infinity;
  const toNightlife = night ? eveningLeg('toNightlife',pm ?? loft,night,depart,lastFare,s.choices.toNightlife) : null;
  return {toDinner,toNightlife};
}
export function trackerFor(s) {
  if (!s.started) return {lines:[],legs:[],cost:0,spent:0,steps:0,calories:0};
  const [transport,am,noon,pm,night] = slots.map(slot => selected(s,slot));
  const lines = [];
  let steps = 0, fares = 0;
  const add = (at,title,url) => lines.push({ time:clock(at), title, url });
  const leg = (a,b,at,mode,label,travel=route(a,b,mode)) => {
    if (travel.minutes) {
      add(at,`${label} · ~${travel.minutes} min`,travel.url);
      steps += travel.steps;
    }
    return at+travel.minutes;
  };
  const checkIn = 9*60+15;
  const firstStop = am ?? loft;
  const firstTime = am ? minutes(am.time) : checkIn;
  let arrival = checkIn;
  if (am) add(firstTime,am.title,am.url);
  if (transport) {
    const mode = travelMode(transport.id);
    const travel = modeRoute(home,firstStop,transport.id);
    const label = am && mode === 'transit' && km(am,loft)>1.6 ? 'Muni' : transport.title;
    arrival = leg(home,firstStop,firstTime-travel.minutes,mode,`${label} to ${firstStop.title}`,travel);
  }
  if (am && transport) {
    const transportMode = travelMode(transport.id);
    const onward = km(am,loft)>1.6 ? transportMode : 'walking';
    const secondLeg = onward === 'walking' ? route(am,loft,onward) : modeRoute(am,loft,transport.id);
    if (onward === 'driving' && secondLeg.minutes > 0) fares += transport.price;
    const leave = Math.max(firstTime + (am.minutes ?? 20), checkIn-secondLeg.minutes-(onward === 'transit' ? 15 : 0));
    const onwardsLabel = onward === 'transit' ? 'Muni' : transport.title;
    arrival = leg(am,loft,leave,onward,onward === 'walking' ? 'Walk to AWS Builder Loft' : `${onwardsLabel} to AWS Builder Loft`,secondLeg);
  }
  const late = arrival > minutes(event.starts);
  if (transport) add(Math.max(arrival,555),late ? 'Arrive at the Loft · after opening remarks begin' : 'Arrive at the Loft · courtyard check-in');
  if (selected(s,'event')) {
    add(570,'Hackathon doors & opening remarks'); add(660,'Kickoff & building time');
    add(990,'Project submission'); add(1020,'Finalist demos & judging'); add(1140,'Awards & closing'); add(1170,'Hackathon ends');
  }
  if (noon) {
    const at = leg(loft,noon,810,'walking',`Walk to ${noon.title}`);
    add(at,noon.title,noon.url);
    leg(noon,loft,at+(noon.minutes ?? 30),'walking','Return to the hackathon');
  }
  const plan = eveningPlan(s);
  const legs = [plan.toDinner?.current,plan.toNightlife?.current].filter(Boolean);
  if (pm && !plan.toDinner?.current) lines.push({time:pm.time,title:pm.title,url:pm.url,slot:'dinner'});
  if (night && !plan.toNightlife?.current) lines.push({time:night.time,title:night.title,url:night.sources[0]?.url,slot:'nightlife'});
  for (const trip of legs) {
    lines.push({time:trip.time,title:`${trip.title} to ${trip.destinationName} · ~${trip.minutes} min`,url:trip.url});
    steps += trip.steps;
    fares += trip.price;
    if (trip.slot === 'toDinner') {
      lines.push({time:trip.arrivesAt,title:pm.title,url:trip.url,slot:'dinner'});
      if (trip.timingNote) lines.push({time:trip.arrivesAt,title:trip.timingNote});
    } else {
      const activity = trip.timingNote ? night.title+' · arrives after closing' : night.title;
      lines.push({time:clock(Math.max(minutes(trip.arrivesAt),minutes(night.time))),title:activity,
        url:night.sources[0]?.url,slot:'nightlife'});
    }
  }
  lines.sort((a,b)=>a.time.localeCompare(b.time));
  const itemTotal = [transport,am,noon,pm,night].reduce((sum,item) => sum+(item?.price ?? 0),0);
  const cost = Math.round((fares+itemTotal)*100)/100;
  const spent = Math.round((s.expenses ?? []).reduce((sum,e) => sum+e.amount,0)*100)/100;
  return {lines,legs,cost,spent,steps,calories:Math.round(steps*0.04)};
}

export function dinnerTextFor(state,tracker) {
  const restaurant = selected(state,'dinner');
  const time = tracker.lines.find(line => line.slot === 'dinner')?.time;
  if (!state.confirmedSlots.includes('dinner') || !restaurant || !time) return null;

  const recipientIds = ['gio','andrew'];
  const recipients = recipientIds.map(id => contacts.find(contact => contact.id === id).name);
  const {id:dinnerId,title:venue,address} = restaurant;
  const [hour,minute] = time.split(':');
  const localTime = `${Number(hour)%12 || 12}:${minute} ${Number(hour)<12 ? 'AM' : 'PM'}`;
  const url = 'https://www.google.com/maps/search/?'+new URLSearchParams({api:'1',query:venue+', '+address});
  const body = `Hey Gio and Andrew! I’m heading to ${venue} at ${localTime} after the hackathon. It’s at ${address}. Want to join me for dinner?`;
  return {dinnerId,venue,address,time,recipientIds,recipients,body,url};
}

export function itineraryBriefing(state, tracker) {
  if (!state.started) return [];
  const morning = selected(state,'breakfast');
  const noon = selected(state,'lunch');
  const evening = selected(state,'dinner');
  const night = selected(state,'nightlife');
  const transit = selected(state,'transit');
  const arrival = tracker.lines.find(line=>line.title.startsWith('Arrive at the Loft'));
  const late = arrival && minutes(arrival.time)>minutes(event.starts);
  const morningMode = transit?.id === 'walk' ? 'on foot' : 'by '+(transit?.id === 'muni' ? 'Muni' : transit?.title);
  const opening = state.profile.trip?.includes('First visit') ? 'Welcome to San Francisco. ' : '';
  return [
    opening+'Your Personal Agents Hackathon opens at 9:30 AM on the second floor of 525 Market Street. Use the courtyard entrance and bring your physical photo ID.'+
      (late ? ` Your route reaches check-in at ${arrival.time}, after the opening begins.` : ''),
    ...(transit ? [`Leave the Richmond pickup around ${tracker.lines[0].time} ${morningMode} for ${morning?.title ?? 'the Loft'}.`] : []),
    ...(morning ? [`Your breakfast stop is ${morning.title}. ${morning.diet}`] : []),
    ...(noon ? [`The organizer provides lunch at 1:30 PM and hasn’t published dietary accommodations. ${noon.id === 'lunch-host' ? 'You selected the hosted meal. Ask the caterer before eating.' : 'Your backup is '+noon.title+'. '+noon.diet}`] : []),
    ...(evening ? [`Your dinner pick is ${evening.title}. ${evening.reservable ? 'You can preview a reservation or invitation draft.' : 'Check availability before leaving the Loft.'}`] : []),
    ...(night ? [`Your nightlife pick is ${night.title}.`] : []),
    ...tracker.legs.filter(leg=>leg.timingNote).map(leg=>leg.timingNote),
    tracker.lines.length ? `Friday’s selected stops and travel come to about $${tracker.cost.toFixed(2)} against your $${state.profile.budget} budget. The walking legs add up to about ${tracker.steps.toLocaleString('en-US')} steps toward your ${state.profile.walkingGoal.toLocaleString('en-US')}-step goal.` : 'Choose transportation and stops to build your route.',
  ];
}
