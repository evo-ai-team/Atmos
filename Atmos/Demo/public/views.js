import { previewPhotos, optionPhotos } from './menu-photos.js';
import { transportArt } from './transport-art.js';
import { routeMap } from './route-map.js';

const iconPaths = {
  locate:'<path d="m21 3-6.8 18-3.1-8.1L3 9.8 21 3Z"/>',
  chevron:'<path d="m9 5 7 7-7 7"/>',
  close:'<path d="m6 6 12 12M18 6 6 18"/>',
  route:'<circle cx="5" cy="18" r="2"/><circle cx="19" cy="6" r="2"/><path d="M7 18h5a4 4 0 0 0 0-8H9a2 2 0 0 1 0-4h8"/>',
  mic:'<rect x="9" y="2" width="6" height="13" rx="3"/><path d="M5 11v1a7 7 0 0 0 14 0v-1M12 19v3m-4 0h8"/>',
  people:'<circle cx="9" cy="8" r="3"/><path d="M3 20v-2a6 6 0 0 1 12 0v2M16 5a3 3 0 0 1 0 6m2 3a5 5 0 0 1 3 5"/>',
  layers:'<path d="m12 3 10 5-10 5L2 8l10-5Zm-9 10 9 5 9-5m-18 5 9 5 9-5"/>',
  energy:'<path d="M14 2c1 5-2 6-1 10 2-1 3-3 3-5 4 3 6 8 3 12a8 8 0 0 1-14-3c-1-5 3-8 5-10 0 2 0 4 1 5 2-3 1-6 3-9Z"/>',
  calendar: '<rect x="3" y="5" width="18" height="16" rx="3"/><path d="M7 3v4m10-4v4M3 10h18"/>',
  event: '<path d="M4 21h16M6 21V6l8-3v18m0-13h4v13M9 9v2m0 3v2m7-5v2"/>',
  transit: '<rect x="5" y="3" width="14" height="15" rx="4"/><path d="M5 10h14m-11 4h.1m7.9 0h.1M8 18l-2 3m10-3 2 3"/>',
  car: '<path d="m4 11 2-6h12l2 6M3 12l1-1h16l1 1v6H3zm3 6v2m12-2v2m-11-6h1m8 0h1"/>',
  walk: '<circle cx="14" cy="4.5" r="1.8"/><path d="m7 12 3-3 3-1 2 4 4 1m-7-5-2 7-4 6m5-7 4 3 2 4"/>',
  breakfast: '<path d="M4 9h13v5a5 5 0 0 1-5 5H9a5 5 0 0 1-5-5zm13 1h2a2.5 2.5 0 1 1 0 5h-2M3 21h17M7 3v3m4-4v4m4-3v3"/>',
  lunch: '<path d="M3 13h18a9 9 0 0 1-18 0Zm2 7h14M5 10l12-6m-6 6 9-4"/>',
  dinner: '<path d="M5 3v5a3 3 0 1 0 6 0V3M8 3v18m10 0V3c-3 2-4 7-3 10h3"/>',
  nightlife: '<path d="M3 5h18l-9 9-9-9Zm9 9v6m-5 1h10M7 9h10"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  pin: '<path d="M19 10c0 5-7 11-7 11S5 15 5 10a7 7 0 1 1 14 0Z"/><circle cx="12" cy="10" r="2.3"/>',
  external: '<path d="M14 4h6v6m-9 3 9-9M10 5H6a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h11a2 2 0 0 0 2-2v-4"/>',
  money: '<rect x="2" y="5" width="20" height="14" rx="2"/><circle cx="12" cy="12" r="3"/><path d="M5 9h1m12 6h1"/>',
  check: '<path d="m4 12 5 5L20 6"/>',
  return: '<path d="m8 4-5 5 5 5M4 9h10a6 6 0 0 1 0 12h-3"/>',
  chart: '<path d="M3 17v3h18M5 13l5-5 4 3 6-7"/>',
  message: '<path d="M21 12a8 8 0 0 1-8 8H5l-3 2 1-6a8 8 0 1 1 18-4Z"/>',
  image: '<rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="8" cy="8" r="1.5"/><path d="m4 18 5-5 3 2 4-5 4 6"/>',
  sparkle: '<path d="m12 3 2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5L12 3Z"/>',
};
export function icon(name) {
  return `<svg class="icon" viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round">${iconPaths[name] ?? iconPaths.pin}</svg>`;
}
export function esc(value) {
  return String(value ?? "").replace(/[&<>"']/g, char => ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" })[char]);
}
export function safeUrl(value, local = false) {
  if (typeof value !== "string" || !value) return "";
  try {
    const parsed = new URL(value, window.location.origin);
    if (local && value.startsWith("/") && parsed.origin === window.location.origin) return parsed.href;
    return ["http:", "https:"].includes(parsed.protocol) && /^https?:\/\//i.test(value) ? parsed.href : "";
  } catch { return ""; }
}
export function link(url, text, className = "") {
  const href = safeUrl(url);
  return href ? `<a href="${esc(href)}" class="${esc(className)}" target="_blank" rel="noopener noreferrer">${text}</a>` : text;
}
function readable(value) {
  if (value == null) return "";
  if (Array.isArray(value)) return value.map(readable).filter(Boolean).join(" · ");
  if (typeof value === "object") return Object.entries(value).map(([key,v])=>`${prettify(key)}: ${readable(v)}`).join(" · ");
  return String(value);
}
function prettify(text) {
  const spaced = text.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/[_-]/g," ");
  return spaced.charAt(0).toUpperCase() + spaced.slice(1);
}
export function profileView(profile) {
  const rows = Object.entries(profile ?? {}).filter(([,v])=>v !== null && v !== "" && v !== undefined);
  if (!rows.length) return "";
  return `<details class="profile"><summary>Preferences in memory</summary><ul class="detail-list">${rows.map(([key,v])=>`<li><strong>${esc(prettify(key))}</strong> · ${esc(readable(v))}</li>`).join("")}</ul></details>`;
}
function money(value) {
  if (typeof value !== "number") return readable(value);
  return value.toLocaleString("en-US",{style:"currency",currency:"USD",maximumFractionDigits:value % 1 ? 2 : 0});
}
function sources(item) {
  const valid = (item?.sources ?? []).filter(s=>s && safeUrl(s.url));
  if (!valid.length) return "";
  return `<div class="source-links"><span class="sourcelabel">Sources</span>${valid.map(s=>link(s.url, esc(s.label || new URL(s.url).hostname) + icon("external"))).join("")}</div>`;
}
function credit(value) {
  if (!value) return "";
  if (typeof value === "string") return esc(value);
  return link(value.url, esc(value.label || value.name || "Photo credit"));
}
function photo(item, className = "venue-photo") {
  const src = safeUrl(item.image, true);
  if (!src) return "";
  const alt = esc(item.imageAlt || item.title || item.place || item.name);
  return `<figure class="${className}"><a href="${esc(src)}" target="_blank" rel="noopener" aria-label="Open photograph of ${alt}"><img src="${esc(src)}" alt="${alt}" loading="lazy"></a>${item.imageCredit ? `<figcaption class="photo-credit">${credit(item.imageCredit)}</figcaption>` : ""}</figure>`;
}
function mapAddress(item) {
  if (!item.address) return "";
  const maps = safeUrl(item.mapUrl || item.mapsUrl) || "https://www.google.com/maps/search/?api=1&query=" + encodeURIComponent(item.title + ", " + item.address);
  return link(maps,icon("pin") + esc(item.address),"address") + (safeUrl(item.url) ? " · " + link(item.url,"Directions","address") : "");
}
function time(value) { return value ? `<span class="section-time">${icon("clock")}${esc(value)}</span>` : ""; }
function detailList(item) {
  const keys = {payment:"Payment",diet:"Dietary fit",menu:"Menu",availability:"Availability",wait:"Expected wait",hours:"Hours",rating:"Rating",reservationNote:"Reservations"};
  const entries = Object.entries(keys).filter(([key])=>item[key] != null && item[key] !== "" && typeof item[key] !== "boolean");
  return entries.length ? `<ul class="detail-list">${entries.map(([key,label])=>`<li><strong>${label}</strong> · ${esc(readable(item[key]))}</li>`).join("")}</ul>` : "";
}
function stats(item) {
  const cells = [];
  if (item.price != null) cells.push(`<span>${icon("money")}<strong>${esc(money(item.price))}</strong> est.</span>`);
  if (Number.isFinite(item.minutes)) cells.push(`<span>${icon("clock")}${item.minutes} min</span>`);
  if (Number.isFinite(item.steps)) cells.push(`<span>${icon("walk")}~${item.steps.toLocaleString("en-US")} steps</span>`);
  return cells.length ? `<div class="option-stats">${cells.join("")}</div>` : "";
}
function info(item, withTitle = true) {
  if (!item) return "";
  return `${withTitle ? `<h4 class="venue-title">${esc(item.title)}</h4>` : ""}${mapAddress(item)}${item.notes ? `<p class="option-note">${esc(readable(item.notes))}</p>` : ""}${stats(item)}${detailList(item)}${sources(item)}`;
}
const checkDateFormat = new Intl.DateTimeFormat("en-US", {
  month:"short", day:"numeric", year:"numeric", hour:"numeric", minute:"2-digit",
  timeZoneName:"short", timeZone:"America/Los_Angeles"
});
const replayDateFormat = new Intl.DateTimeFormat("en-CA", {
  year:"numeric", month:"2-digit", day:"2-digit", hour:"2-digit", minute:"2-digit",
  hourCycle:"h23", timeZone:"America/Los_Angeles"
});
function checkDate(value) {
  const date = new Date(value);
  return value && Number.isFinite(date.getTime()) ? checkDateFormat.format(date) : "";
}
function replayStamp(instant) {
  if (!checkDate(instant)) return "";
  const parts = Object.fromEntries(replayDateFormat.formatToParts(new Date(instant)).map(p => [p.type,p.value]));
  return `${parts.year}-${parts.month}-${parts.day} ${parts.hour}:${parts.minute}`;
}
function organizerFacts(facts,event) {
  if (!facts?.start || !event) return "";
  const changed = replayStamp(facts.start) !== event.date+" "+event.starts
    || (facts.end && replayStamp(facts.end) !== event.date+" "+event.ends)
    || (facts.eventStatus && facts.eventStatus !== "Scheduled");
  return `<p>Organizer start · ${esc(checkDate(facts.start))}</p>
    ${facts.end ? `<p>Organizer end · ${esc(checkDate(facts.end))}</p>` : ""}
    ${facts.eventStatus ? `<p>Organizer status · ${esc(facts.eventStatus)}</p>` : ""}
    ${changed ? `<p class="changed-facts"><strong>Different from the replay</strong><br>
      Replay schedule · ${esc(event.date)} · ${esc(event.time)}</p>` : ""}`;
}
function evidencePanel(evidence,catalog) {
  if (!evidence) return "";
  const rows = (evidence.sources || []).map(source => {
    const checkedAt = checkDate(source.checkedAt);
    const lastGood = checkDate(source.lastGoodAt);
    return `<li>
      <strong>${link(source.url,esc(source.label)+icon("external"))}</strong>
      <p>${esc(source.status)}</p>
      ${checkedAt ? `<p>Checked · ${esc(checkedAt)}</p>` : ""}
      ${lastGood && source.lastGoodAt !== source.checkedAt ? `<p>Last verified · ${esc(lastGood)}</p>` : ""}
      ${organizerFacts(source.facts,catalog.event)}
      ${source.id === "weather" && evidence.weather ? `<p>${esc(evidence.weather)}</p>` : ""}
      ${source.facts?.sha256 && source.changedAt ? `<p>Menu file version first seen · ${esc(checkDate(source.changedAt))}</p>` : ""}
    </li>`;
  }).join("");
  return `<details class="tips source-checks">
    <summary>Source checks</summary><p>${esc(evidence.status)}</p>
    <ul>${rows}</ul>
  </details>`;
}
function toolsPanel(data) {
  const {catalog,state,memoryStatus,evidence}=data;
  const tracker = data.tracker;
  return `<details class="trip-tools glass"><summary>${icon("layers")}Trip tools</summary><div class="tools-body">
   <details class="tips expenses"><summary>Spending log · ${esc(money(tracker.spent ?? 0))}</summary><p>Daily budget · ${esc(money(state.profile.budget))}</p>
   ${(state.expenses || []).length ? `<ul class="expense-list">${state.expenses.map(entry=>`<li><span>${esc(entry.label)}</span><strong>${esc(money(entry.amount))}</strong></li>`).join("")}</ul>` : ""}
   <form id="expense-form"><label>Expense<input name="label" maxlength="80" placeholder="e.g. Clipper fare" required></label><label>Amount (USD)<input name="amount" type="number" min="0.01" max="10000" step="0.01" placeholder="0.00" required></label><button class="btn secondary" type="submit">Log expense</button></form></details>
   <details class="tips"><summary>Weather & visitor tips</summary>${catalog.weather ? `<p>${esc(readable(catalog.weather))}</p>` : ""}<ul>${(catalog.visitorTips ?? []).map(tip=>`<li>${esc(readable(tip))}</li>`).join("")}</ul>${sources({sources:[...(catalog.weatherSources || []),...(catalog.visitorSources || catalog.tipSources || [])]})}</details>
   <div class="trip-memory">${profileView(state.profile)}</div>
   ${evidencePanel(evidence,catalog)}
   <details class="tips recall"><summary>Recall a memory</summary>
     <form id="recall-form"><label>Search in<select name="scope"><option value="private">My trip</option><option value="shared">City guide</option></select></label>
       <label>Search memory<input name="query" type="search" placeholder="e.g. breakfast" maxlength="250" required></label>
       <button class="btn secondary" type="submit">Search</button>
     </form><p id="recall-status" role="status">${esc(memoryStatus)}</p><ul id="recall-results"></ul>
   </details>
   <button type="button" class="text-button" data-action="alert">Show demo notification</button>
   ${state.started ? `<button type="button" class="text-button reset-button" data-reset>Reset demo</button>` : ""}
   </div></details>`;
}
export function alertView(alert) {
  return `<div class="dialog-heading"><span class="post-network"><b aria-hidden="true">𝕏</b> Fictional demo post</span><button type="button" class="icon-button" data-close="alert-dialog" aria-label="Close interruption">×</button></div>
    <h2 id="alert-title">${esc(alert.title)}</h2><blockquote class="team-post">
      <p>${esc(alert.caption)}</p>${photo(alert,"alert-photo")}
      ${alert.place ? `<p class="post-place">${icon("pin")}${esc(alert.place)}</p>` : ""}</blockquote>
    <p class="subtle">${esc(alert.notes)}</p>
    ${alert.alternative ? `<details class="alternate-dinner"><summary>Suggested dinner · ${esc(alert.alternative.split(" at ")[0])}</summary><p>${esc(alert.alternative)}</p></details>` : ""}
    <div class="dialog-actions"><button type="button" class="btn secondary" data-action="dismiss">Keep my plan</button><button type="button" class="btn primary" data-action="reroute">Reroute my evening</button></div>`;
}

const slotNames = { transit:"Transportation", breakfast:"Breakfast", event:"Hackathon", lunch:"Lunch", toDinner:"Travel to dinner", dinner:"Dinner", toNightlife:"Travel to nightlife", nightlife:"Nightlife" };
export const routeSlots = Object.keys(slotNames);
const clockFormat = new Intl.DateTimeFormat("en-US", { hour:"numeric", minute:"2-digit", timeZone:"America/Los_Angeles" });
export function updateClock() {
  const clock = document.getElementById("local-clock");
  if (!clock) return;
  const now = new Date();
  const parts = Object.fromEntries(clockFormat.formatToParts(now).map(p=>[p.type,p.value]));
  clock.dateTime = now.toISOString();
  clock.querySelector("b").textContent = parts.hour+":"+parts.minute;
  clock.querySelector("small").textContent = parts.dayPeriod;
}
function displayTime(value) {
  const match = /^(\d{1,2}):(\d{2})$/.exec(value || "");
  if (!match) return value || "";
  const hour = Number(match[1]);
  return (hour % 12 || 12)+":"+match[2]+(hour>=12 ? " PM" : " AM");
}
function activeOption(data,slot) {
  const rows = data.catalog[slot];
  return rows.find(o=>o.id === data.state.choices[slot]) || rows.find(o=>o.available !== false);
}
function tracking(data) {
  return data.state.started ? data.tracker : data.previewTracker || data.tracker;
}
function venueName(o) { return o.title.split(" · ")[0]; }
function roundButton(attributes, symbol, label, className="") {
  return `<button type="button" ${attributes} class="round ${className}" title="${esc(label)}" aria-label="${esc(label)}">${icon(symbol)}</button>`;
}
const rideNames = {walk:"Walk",muni:"Muni",waymo:"Waymo",tesla:"Tesla Robotaxi",taxi:"Taxi"};
const mealSlots = ["breakfast","lunch","dinner"];
function isEveningLeg(slot) { return slot === "toDinner" || slot === "toNightlife"; }
function isTravel(slot) { return slot === "transit" || isEveningLeg(slot); }
function legSuffix(slot) { return slot==="toDinner" ? " to dinner" : slot==="toNightlife" ? " to nightlife" : ""; }
function slotOptions(data,slot) {
  return slot === "event" ? [data.catalog.event] : data.catalog[slot];
}
function optionName(slot,item) {
  return isTravel(slot) ? rideNames[item.id] || item.title : venueName(item);
}
function choiceArt(slot,item) {
  const src = isTravel(slot) ? transportArt[item.id]?.src : optionPhotos[item.id] || previewPhotos[item.id]?.[0]?.src;
  return `<span class="choice-art ${isTravel(slot) ? "brand-box "+esc(item.id) : ""}">${src ? `<img src="${esc(src)}" alt="">` : icon(item.id === "walk" ? "walk" : slot)}</span>`;
}
function choiceButton(slot,item,savedId) {
  const name = optionName(slot,item);
  const destination = legSuffix(slot);
  const branch = ["breakfast","breakfast-battery"].includes(item.id) ? item.title.split(" · ")[1] : "";
  const saved = savedId === item.id;
  return `<button type="button" class="choice-tile" data-preview="${esc(item.id)}" data-slot="${slot}"
    aria-label="${esc("Preview "+name+destination+(branch ? ", "+branch : "")+(saved ? ", on your route" : ""))}">
    <span class="tile-art">${choiceArt(slot,item)}${saved ? `<i class="saved-mark">${icon("check")}</i>` : ""}</span>
    <strong>${esc(name)}</strong>${branch ? `<small>${esc(branch)}</small>` : ""}
    ${isEveningLeg(slot) ? `<small>~${esc(item.minutes)} min</small>` : ""}
  </button>`;
}
function gallery(slot,item) {
  const photos = previewPhotos[item.id] || [];
  return photos.length ? `<div class="menu-strip${photos.length>3 ? " scrollable" : ""}" aria-label="${slotNames[slot]} photos">${photos.map((p,i)=>`
    <button class="dish" type="button" data-photo-id="${esc(item.id)}" data-photo-slot="${slot}" data-photo-index="${i}" aria-label="${esc(p.label)} · view photo">
      <img src="${esc(p.src)}" alt=""><span>${esc(p.label)}</span>
    </button>`).join("")}</div>` : "";
}
function selectionActions(slot,item,confirmed) {
  const name = optionName(slot,item)+legSuffix(slot);
  const options = isEveningLeg(slot) ? (slot==="toDinner" ? "dinner travel" : "nightlife travel") : slotNames[slot].toLowerCase();
  return `<div class="selection-actions">${confirmed
    ? roundButton(`data-options="${slot}"`,"return","Return to "+options+" options","return-choice")
    : roundButton(`data-action="choose" data-slot="${slot}" data-id="${esc(item.id)}"`,"check","Confirm "+name,"included")
      + roundButton(`data-options="${slot}"`,"close","Cancel "+name+" preview","excluded")}</div>`;
}
function rideDetails(item) {
  const walking = item.id === "walk";
  const distance = Number.isFinite(item.distanceKm) ? `${item.distanceKm.toFixed(1)} km` : "";
  return `<dl class="ride-facts">
    <div><dt>${walking && distance ? "Distance" : "Expected wait"}</dt><dd>${esc(walking && distance ? distance : item.wait || "Check service")}</dd></div>
    <div><dt>${walking ? "Walking time" : "Travel time"}</dt><dd>${esc(item.minutes)} min</dd>${!walking && distance ? `<dd class="ride-distance">${esc(distance)}</dd>` : ""}</div>
    <div><dt>Est. fare</dt><dd>${esc(money(item.price))}</dd></div>
    </dl>${!walking && item.waitNote ? `<p class="ride-note">${esc(item.waitNote)}</p>` : ""}
    ${item.timingNote ? `<p class="timing-note">${esc(item.timingNote)}</p>` : ""}
    ${walking ? `<p class="ride-payment">${icon("walk")}About ${Number(item.steps).toLocaleString("en-US")} steps</p>` :
      `<p class="ride-payment">${icon("money")}${esc(item.payment)}</p>`}`;
}
function stopBody(slot,item,confirmed) {
  const detail = isTravel(slot) ? (item.id==="walk" ? "Walk details" : "Ride details") : mealSlots.includes(slot) ? "Menu & dietary details" : "Venue details";
  return `${isTravel(slot) ? rideDetails(item) : gallery(slot,item)}
    <div class="stop-links">
      <button class="sheet-link" data-detail="${slot}" data-item-id="${esc(item.id)}">${detail} ${icon("chevron")}</button>
      ${isTravel(slot) ? link(item.url,"Directions "+icon("external"),"sheet-link") : ""}
      ${slot==="dinner" && confirmed ? '<button class="sheet-link" data-group-invite>Invite Gio &amp; Andrew</button>' : ""}
    </div>`;
}
export function routeSection(data,slot,edit) {
  const options = slotOptions(data,slot);
  if (!options?.length) return "";
  const saved = data.state.confirmedSlots.includes(slot) && !data.state.skippedSlots?.includes(slot);
  const leg = isEveningLeg(slot) && tracking(data).legs?.find(l=>l.slot===slot);
  const selected = options.find(o=>o.id===(data.state.choices[slot] || leg?.id)) || options[0];
  const confirmed = saved && edit === undefined;
  const item = confirmed ? selected : options.find(o=>o.id===edit);
  const reference = item || selected;
  const at = tracking(data).lines.find(line=>line.title===reference.title || (slot==="nightlife" && selected.id===reference.id && line.slot===slot))?.time;
  const when = slot === "transit" ? "" : displayTime(at || (slot === "event" ? reference.starts : reference.time));
  const title = slotNames[slot];
  const routed = isTravel(slot) && reference.originName && reference.destinationName;
  const routeLabel = routed ? `${reference.originName.split(" · ")[0]} → ${reference.destinationName.split(" · ")[0]}` : "";
  const timing = routed ? `Leave ${displayTime(reference.time)}${item?.arrivesAt ? " · Arrive "+displayTime(item.arrivesAt) : ""}` : when;
  const id = slot === "transit" ? "transit" : "slot-"+slot;
  return `<section class="stop glass stop-${slot}${item ? " expanded" : ""}" id="${id}" aria-labelledby="${id}-heading">
    <div class="stop-head">
      <span class="stop-pin pin-${isTravel(slot) ? "transit" : slot}">${icon(item?.id === "walk" ? "walk" : isEveningLeg(slot) ? "route" : slot)}</span><div class="stop-title">
        ${item ? `<span class="stop-type">${title}${timing ? `<i></i><span>${esc(timing)}</span>` : ""}</span>` : ""}
        <h2 id="${id}-heading">${item ? esc(optionName(slot,item)) : title}</h2>
        ${routeLabel ? `<small>${esc(routeLabel)}</small>` : ""}
        ${!item && timing ? `<span class="section-time">${esc(timing)}</span>` : ""}
        ${item && slot==="transit" && item.title!==optionName(slot,item) ? `<small>${esc(item.title)}</small>` : ""}
        ${item && !isTravel(slot) ? `<small>${esc(item.address)}</small>` : ""}
      </div>${item ? selectionActions(slot,item,confirmed) : ""}</div>
    ${item ? stopBody(slot,item,confirmed) : `<div class="choices" role="group" aria-label="${title} options">${options.map(o=>choiceButton(slot,o,saved ? selected.id : null)).join("")}</div>`}
  </section>`;
}
function locationMap(data) {
  return `<section class="map-stage" aria-labelledby="location-title">
    ${routeMap(data)}
    <div class="map-inner">
      <div class="location glass"><div class="location-context"><i class="gps-dot"></i>Current location <span>· Demo GPS</span></div>
        <time id="local-clock"><b></b><small></small></time>
        <h1 id="location-title">Richmond District</h1><p>San Francisco, CA</p>
      </div>
      <button type="button" id="brief-button" class="brief-trigger glass" aria-label="Trip briefing">${icon("mic")}<span>Trip briefing</span></button>
      <div class="map-actions">
        ${roundButton('data-detail="map"','locate','View route and simulated GPS','glass')}
      </div>
    </div>
  </section>`;
}
function nearby(data) {
  const dinnerChosen = data.state.confirmedSlots.includes("dinner");
  return `<section class="people glass" id="people" aria-labelledby="nearby-title">
    <div class="section-label"><span class="section-symbol">${icon("people")}</span><h2 id="nearby-title">People nearby</h2></div>
    ${data.catalog.contacts.map(person=>`<button class="person" data-detail="person" data-person="${esc(person.id)}">
      <span class="person-avatar"><img src="${esc(person.image)}" alt=""><i>${person.id==="gio" ? "◎" : "𝕏"}</i></span>
      <span class="person-text"><strong>${esc(person.name)}</strong><small>${esc(person.place)}</small></span>
      ${icon("chevron")}
    </button>`).join("")}
    <button class="group-invite" type="button" ${dinnerChosen ? "data-group-invite" : "data-pick-dinner"}>
      ${icon("message")}${!dinnerChosen ? "Choose dinner to invite" : data.state.sentDinnerTexts?.some(m=>m.key===data.dinnerTextDraft?.key) ? "Replay dinner invitation" : "Invite both to dinner"}
    </button>
    ${data.state.sentDinnerTexts?.length ? '<button type="button" class="sheet-link" data-show-messages>View messages</button>' : ""}
  </section>`;
}
function groupAvatars() {
  return '<span class="group-avatars" aria-hidden="true"><b>G</b><b>A</b></span>';
}
export function messageApproval(draft) {
  return `<div class="approval-to">${groupAvatars()}<div><small>To</small><strong>${draft.recipients.map(esc).join(" &amp; ")}</strong></div></div>
    <p class="preview-bubble">${esc(draft.body)}</p>
    <p class="subtle">Simulated iMessage · 2 recipients</p>
    <div class="dialog-actions">
      <button class="btn secondary" data-close="detail-dialog">Cancel</button>
      <button class="btn primary" data-approve-text data-key="${esc(draft.key)}">Approve to send</button>
    </div><p id="approval-status" role="status"></p>`;
}
function conversation(state, options) {
  if (!options.open || !state.sentDinnerTexts?.length) return "";
  const history = state.sentDinnerTexts;
  return `<section class="imessage glass" id="group-thread" tabindex="-1" aria-labelledby="thread-heading">
    <div class="message-top"><span>iMessage · Demo</span>${roundButton("data-hide-messages","close","Hide conversation")}</div>
    <div class="conversation-head">${groupAvatars()}<h2 id="thread-heading">Gio &amp; Andrew</h2></div>
    <ol class="messages">${history.map(m=>{
      const pending = options.sendingId === m.id;
      const sentTime = clockFormat.format(new Date(m.sentAt));
      return `<li${pending ? ' class="message-new"' : ''}><time datetime="${esc(m.sentAt)}">${esc(sentTime)}</time>
        <div class="sent-bubble">${esc(m.body)}</div>
        ${link(m.url,`${icon("pin")}<span><strong>${esc(m.venue.split(" · ")[0])} · ${esc(displayTime(m.time))}</strong><small>${esc(m.address)}</small></span>`,"shared-place")}
        <span class="delivery" role="status">${pending ? "Sending…" : "Delivered"}</span>
      </li>`;
    }).join("")}</ol>
  </section>`;
}
function trackerCard(data) {
  const {profile} = data.state;
  const track = tracking(data);
  const summaries = [];
  for (const slot of routeSlots.slice(1)) {
    if (data.state.skippedSlots?.includes(slot)) continue;
    if (isEveningLeg(slot)) {
      const leg = track.legs?.find(l=>l.slot===slot);
      if (leg) summaries.push(`<li class="tracker-leg">${icon(leg.id==="walk" ? "walk" : "route")}<span>${esc(optionName(slot,leg))} · ~${esc(leg.minutes)} min</span><time>${esc(displayTime(leg.time))}</time></li>`);
      continue;
    }
    const o = slot==="event" ? data.catalog.event : activeOption(data,slot);
    if (!o) continue;
    const found = track.lines.find(line => line.title===o.title || line.slot===slot);
    summaries.push(`<li><i class="dot-${slot}"></i><span>${esc(slot==="event" ? "AWS Builder Loft" : venueName(o))}</span>
      <time>${esc(displayTime(found?.time || (slot==="event" ? o.starts : o.time)))}</time></li>`);
  }
  return `<section class="tracker glass" id="tracker">
    <div class="section-label"><span class="section-symbol">${icon("route")}</span><h2>Trip tracker</h2></div>
    <div class="metrics">
      <div><span>${icon("money")} Est. spend</span><strong>${esc(money(track.cost))}</strong><small>of ${esc(money(profile.budget))}</small></div>
      <div><span>${icon("walk")} Steps</span><strong>${Number(track.steps).toLocaleString("en-US")}</strong><small>of ${Number(profile.walkingGoal).toLocaleString("en-US")}</small></div>
      <div><span>${icon("energy")} Energy</span><strong>${track.calories}</strong><small>est. kcal</small></div>
    </div>
    <ol class="mini-route">${summaries.join("")}</ol>
    <button class="sheet-link" data-detail="schedule">Full schedule ${icon("chevron")}</button>
  </section>`;
}
export function dashboard(data,edits = {},thread = {}) {
  return `${locationMap(data)}
    <div class="workspace">
      <section class="route-column" id="day-plan" aria-label="Today's route">
        ${routeSection(data,"transit",edits.transit)}
        <div class="stops">${routeSlots.slice(1).map(s=>routeSection(data,s,edits[s])).join("")}</div>
      </section>
      <aside class="sidebar">${nearby(data)}${conversation(data.state,thread)}${trackerCard(data)}${toolsPanel(data)}</aside>
    </div>`;
}
export function detailsFor(data,kind,id) {
  const {catalog,state} = data;
  if (isEveningLeg(kind)) {
    const leg = slotOptions(data,kind)?.find(o=>o.id===id);
    if (!leg) return;
    return {title:optionName(kind,leg)+" · "+slotNames[kind],body:`
      <p>${esc(leg.originName)} · ${esc(leg.origin)}</p>
      <p>${esc(leg.destinationName)} · ${esc(leg.destination)}</p>
      <p>${esc(leg.notes)}</p>${stats(leg)}${detailList(leg)}${sources(leg)}
      ${link(leg.url,"Open directions "+icon("external"),"btn secondary")}`};
  }
  if (kind==="transit" || kind==="map") {
    const opt = catalog.transit.find(o=>o.id===id) || activeOption(data,"transit");
    const art = transportArt[opt.id];
    return { title:kind==="map" ? "Morning route" : opt.id==="walk" ? "Your walk" : "Your ride", body:`
      <p>${esc(catalog.origin)}</p>
      ${info(opt)}${art?.source ? link(art.source,"Service icon source","photo-credit") : ""}
      ${kind==="map" ? `<button class="btn secondary" data-commute>${icon("route")}Replay commute</button><div id="commute-replay" role="status"></div>` : ""}
      <p class="photo-credit">Map data · ${link("https://www.openstreetmap.org/copyright","OpenStreetMap contributors")} · ${link("https://openfreemap.org/","OpenFreeMap")} · ${link("https://openmaptiles.org/","OpenMapTiles")} · ${link("https://data.sf.gov/d/9exe-acju","SFMTA routes")}</p>` };
  }
  if (kind==="person") {
    const c = catalog.contacts.find(p=>p.id===id);
    if (!c) return;
    return {title:c.name,body:`<p class="subtle">${esc(c.platform)} · fictional post</p>
      ${photo(c,"post-photo")}<p>${esc(c.caption)}</p><p class="address">${icon("pin")}${esc(c.place)}</p>
      ${!state.confirmedSlots.includes("dinner") ? '<button class="btn primary" data-pick-dinner>Choose dinner to invite</button>' : `<button class="btn primary" data-group-invite>Invite Gio &amp; Andrew</button>
      <button class="btn secondary" type="button" data-action="invite" data-id="${esc(c.id)}">
      ${state.invitations.includes(c.id)?"Review individual draft":"Draft individual invite"}</button>`}`};
  }
  if (kind==="schedule") {
    const schedule = tracking(data).lines.map(l=>`<li><time>${esc(displayTime(l.time))}</time>${link(l.url,esc(l.title))}</li>`).join("");
    return {title:"Full schedule",body:`<ol class="schedule">${schedule}</ol>`};
  }
  const item = slotOptions(data,kind)?.find(option=>option.id===id);
  if (!item) return;
  const chosen = state.confirmedSlots.includes(kind) && state.choices[kind]===id;
  return {title:item.title,body:`${info(item,false)}
    ${chosen && mealSlots.includes(kind) ? `<button class="btn secondary" data-action="skip" data-slot="${kind}">Skip this meal</button>` : ""}
    ${chosen && kind==="dinner" && item.reservable ? '<button class="btn secondary" data-action="reserve">Draft reservation</button>' : ""}`};
}
export function menuPhotoFor(data,slot,id,index) {
  const venue = slotOptions(data,slot)?.find(o=>o.id===id);
  const p = previewPhotos[id]?.[index];
  if (!venue || !p) return;
  return {title:p.label,body:`<img class="dish-full" src="${esc(p.src)}" alt="${esc(p.label)}">
    <p>${esc(venueName(venue))} · ${link(p.source,"Photo source")}</p>${detailList({diet:venue.diet})}`};
}
export function briefingView(data) {
  return data.state.started && data.briefing?.length ? `<details class="brief-response"><summary>Atmos’ itinerary</summary>
    ${data.briefing.map(p=>`<p>${esc(p)}</p>`).join("")}
    ${window.speechSynthesis && window.SpeechSynthesisUtterance ? '<button class="btn secondary" id="read-guide" type="button">Read aloud</button><p id="reading-status" role="status"></p>' : ""}
  </details>` : "";
}
