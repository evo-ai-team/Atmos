import { createHash } from 'node:crypto';
import { event, transit, nightlife, weekend, visitorTips, visitorSources, weather, weatherSources, origin, originCoords } from './city.mjs';
import { breakfast, lunch, dinner } from './food.mjs';

export const intro = "Hey Atmos, I'm visiting Richmond SF for the first time from Singapore for work, and I signed up for a hackathon at the AWS building. I've told my boss I'm sick today because I really wanted to attend this event and meet cool people. I'm here until Sunday and want to explore the best food and entertainment this city has to offer. Can you plan my itinerary for me?";
const heroImage = '/assets/san-francisco.jpg';
const contacts = [
  { id: 'gio', name: 'Gio L.', platform: 'Instagram story', caption: 'First stop in SF 🌉 Anyone around for dinner?', place: 'Golden Gate Bridge', image: heroImage },
  { id: 'andrew', name: 'Andrew S.', platform: 'X post', caption: 'In San Francisco for the Systems Forum. Free once the last session wraps!', place: 'SF Systems Forum', image: '/assets/forum.jpg' },
];
const loft = { address: event.address, coords: event.coords ?? [37.7906, -122.3992] };
const home = { address: 'Clement St & 14th Ave, San Francisco, CA', coords: originCoords };
// The image and its transcription are paired test fixtures. Match the visible
// business name and street to the demo gazetteer, independent of who is pictured.
const teamPost = { caption: 'Dinner with the team! :)', observedSigns: ['FERRY LANE KITCHEN', 'MARKET ST'] };
const demoVenues = [{ title: 'Ferry Lane Kitchen', street: 'Market St', coords: [37.7900, -122.4001] }];
const teamVenue = demoVenues.find(v => [v.title, v.street].every(s => teamPost.observedSigns.includes(s.toUpperCase())));
const alert = {
  title: 'Your boss just posted on X', caption: teamPost.caption, place: teamVenue.title, image: '/assets/team-dinner.jpg',
  notes: `The sign reads “${teamVenue.title}” and the street sign reads “${teamVenue.street}”. This fictional venue is about ${Math.round(km(loft, teamVenue) * 1000 / 25) * 25} m from the Loft. You can switch dinner to another neighborhood.`,
};
export const catalog = { date: '2026-11-20', intro, heroImage, heroCredit: { label: 'Rich Niewiroski Jr. · CC BY 2.5', url: 'https://commons.wikimedia.org/wiki/File:GoldenGateBridge-001.jpg' }, origin, originCoords, event, transit, breakfast, lunch, dinner, nightlife, weekend, contacts, visitorTips, visitorSources, weather, weatherSources, alert };
export const catalogRevision = createHash('sha256').update(JSON.stringify(catalog)).digest('hex');
const slots = ['transit','breakfast','lunch','dinner','nightlife'];
export const defaultProfile = { diet: 'Vegan, dairy-free, gluten-free', walkingGoal: 2000, budget: 400, socialStatus: 'Socialize', habits: 'Coffee and breakfast around 8 AM. Likes an evening drink.' };
export function searchLocalMemory(guide, state, scope, query) {
  const facts = scope === 'private'
    ? [...Object.entries(state.profile).filter(([,v])=>typeof v !== 'boolean').map(([k,v]) => `${k}: ${v}`),
      ...Object.entries(state.choices).map(([slot,id])=>`${slot}: ${guide[slot]?.find(o=>o.id===id)?.title ?? ''}`)]
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
  return { started: false, transcript: '', revision: 0, profile: { ...defaultProfile }, choices: {}, confirmedSlots: [], invitations: [], reservation: null, expenses: [], alert: 'idle' };
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
function selected(s, slot) { return catalog[slot].find(o => o.id === s.choices[slot]); }
function alternateDinner(s) {
  const candidates = dinner.filter(o => o.available !== false && o.id !== s.choices.dinner && km(o, teamVenue) > 1);
  return candidates.sort((a,b) => Number(!!b.reservable) - Number(!!a.reservable) || km(b,teamVenue) - km(a,teamVenue))[0];
}

export function guideForVisit(guide,s,evidence) {
  const pm = selected(s,'dinner');
  const alternate = alternateDinner(s);
  return {
    ...guide,
    weather:evidence?.weather ?? guide.weather,
    alert:{...guide.alert,alternative:alternate && `${alternate.title} at ${alternate.address}. ${alternate.diet}`},
    nightlife:pm ? guide.nightlife.map(night=>({
      ...night,url:route(pm,night,km(pm,night)>1.6 ? 'transit' : 'walking').url,
    })) : guide.nightlife,
  };
}
function changeDinner(s, id) {
  if (s.choices.dinner !== id) { s.invitations = []; s.reservation = null; }
  s.choices.dinner = id;
}
export function updateState(previous, input) {
  if (!input || typeof input !== 'object') throw new InputError('Choose a demo action.');
  const s = structuredClone(previous);
  if (input.action === 'reset') return { ...newState(), revision: s.revision + 1 };
  if (input.action === 'start') {
    if (typeof input.transcript !== 'string' || !input.transcript.trim() || input.transcript.length > 6000) throw new InputError('Enter a trip briefing of up to 6,000 characters.');
    if (!/hackathon|richmond|san francisco|\bsf\b/i.test(input.transcript)) throw new InputError('This test itinerary covers the San Francisco hackathon. Use the sample briefing or mention that trip.');
    s.started = true; s.transcript = input.transcript.trim(); s.profile = profileFrom(s.transcript);
    for (const slot of slots) s.choices[slot] ??= catalog[slot].find(o => o.available !== false)?.id;
    if (!s.profile.discretion) s.alert = 'idle';
  } else {
    if (!s.started) throw new InputError('Start your trip briefing first.');
    switch (input.action) {
      case 'choose': {
        if (!slots.includes(input.slot)) throw new InputError('Unknown itinerary segment.');
        const o = catalog[input.slot].find(option => option.id === input.id);
        if (!o || o.available === false) throw new InputError('This option is unavailable.');
        if (input.slot === 'dinner') changeDinner(s, o.id);
        else s.choices[input.slot] = o.id;
        if (!s.confirmedSlots.includes(input.slot)) s.confirmedSlots.push(input.slot);
        if (input.slot === 'nightlife' && s.profile.discretion && s.alert === 'idle') s.alert = 'shown';
        break;
      }
      case 'invite':
        if (!contacts.some(c => c.id === input.id) || s.profile.socialStatus !== 'Socialize' || !s.confirmedSlots.includes('dinner')) throw new InputError('Confirm a dinner venue before drafting an invitation.');
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
        if (!s.confirmedSlots.includes('dinner')) s.confirmedSlots.push('dinner');
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
  return { minutes:duration, steps:Math.round(walkingKm*1350), url:url.href, mode };
}
export function trackerFor(s) {
  if (!s.started) return {lines:[],cost:0,spent:0,steps:0,calories:0};
  const [transport,am,noon,pm,night] = slots.map(slot => selected(s,slot));
  const transportMode = transport.id === 'muni' ? 'transit' : 'driving';
  const lines = [];
  let steps = 0, fares = 0;
  const add = (at,title,url) => lines.push({ time:clock(at), title, url });
  const leg = (a,b,at,mode,label) => {
    const travel = route(a,b,mode);
    if (travel.minutes) {
      add(at,`${label} · ~${travel.minutes} min`,travel.url);
      steps += travel.steps;
    }
    return at+travel.minutes;
  };
  const breakfastTime = minutes(am.time);
  const firstTravel = route(home,am,transportMode);
  const firstMode = transportMode === 'transit' && km(am,loft)>1.6 ? 'Muni' : transport.title;
  leg(home,am,breakfastTime-firstTravel.minutes,transportMode,`${firstMode} to ${am.title}`);
  add(breakfastTime,am.title,am.url);
  const onward = km(am,loft)>1.6 ? transportMode : 'walking';
  const secondLeg = route(am,loft,onward);
  if (onward === 'driving' && secondLeg.minutes > 0) fares += transport.price;
  const leave = Math.max(breakfastTime + (am.minutes ?? 20), 9*60+15-secondLeg.minutes-(onward === 'transit' ? 15 : 0));
  const onwardsLabel = onward === 'transit' ? 'Muni' : transport.title;
  const arrival = leg(am,loft,leave,onward,onward === 'walking' ? 'Walk to AWS Builder Loft' : `${onwardsLabel} to AWS Builder Loft`);
  add(Math.max(arrival,555),'Arrive at the Loft · courtyard check-in');
  add(570,'Hackathon doors & opening remarks');
  add(660,'Kickoff & building time');
  let at = leg(loft,noon,810,'walking',`Walk to ${noon.title}`);
  add(at,noon.title,noon.url);
  leg(noon,loft,at+(noon.minutes ?? 30),'walking','Return to the hackathon');
  add(990,'Project submission'); add(1020,'Finalist demos & judging'); add(1140,'Awards & closing'); add(1170,'Hackathon ends');
  const nightLeg = (from,to,time) => {
    const mode = km(from,to)>1.6 ? 'transit' : 'walking';
    if (mode === 'transit') {
      // Charge a second fare only when the last transfer has expired.
      if (time-lastPaid > 120) { fares += catalog.transit.find(t => t.id==='muni').price; lastPaid = time; }
    }
    return leg(from,to,time,mode,`${mode === 'transit' ? 'Muni' : 'Walk'} to ${to.title}`);
  };
  let lastPaid = -Infinity;
  at = nightLeg(loft,pm,1170); add(at,pm.title,pm.url);
  at = nightLeg(pm,night,at+(pm.minutes ?? 60)); add(Math.max(at,minutes(night.time)),night.title,night.sources[0]?.url);
  const cost = Math.round((fares+[transport,am,noon,pm,night].reduce((sum,o) => sum+o.price,0))*100)/100;
  const spent = Math.round((s.expenses ?? []).reduce((sum,e) => sum+e.amount,0)*100)/100;
  return {lines,cost,spent,steps,calories:Math.round(steps*0.04)};
}
