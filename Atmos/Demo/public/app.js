import { alertView, credit, dashboard, esc, profileView, safeUrl } from "./views.js";

const $ = selector => document.querySelector(selector);
const content = $("#dashboard");
const brief = $("#brief-dialog");
const interruption = $("#alert-dialog");
const draftDialog = $("#draft-dialog");
const transcript = $("#transcript");
const voiceButton = $("#voice-button");
const voiceStatus = $("#voice-status");
let data;
let sending = false;
let transitExpanded = false;
let queuedChoice;
let noticeTimer;
let recognition;
let navObserver;
let replayTimer;
let activeReading;

function stopReading() {
  if (!activeReading) return;
  activeReading = null;
  window.speechSynthesis.cancel();
  const button = $("#read-guide");
  if (button) {
    button.textContent = "Read aloud";
    button.setAttribute("aria-pressed","false");
    $("#reading-status").textContent = "Reading stopped.";
  }
}

function readGuide(button) {
  if (activeReading) {stopReading(); return;}
  const paragraphs = data.briefing.filter(text => typeof text === "string" && text.trim());
  const speech = window.speechSynthesis;
  const voice = speech.getVoices().find(v => v.localService && /^en\b/i.test(v.lang));
  const sentences = paragraphs.map(text => {
    const utterance = new window.SpeechSynthesisUtterance(text);
    utterance.lang = "en-US";
    if (voice) utterance.voice = voice;
    return utterance;
  });
  if (!sentences.length) return;
  activeReading = sentences;
  button.textContent = "Stop reading";
  button.setAttribute("aria-pressed","true");
  const status = $("#reading-status");
  status.textContent = "Reading Atmos’ briefing.";
  function finished(message) {
    if (activeReading !== sentences) return;
    stopReading();
    status.textContent = message;
  }
  sentences.at(-1).onend = () => finished("Finished reading the briefing.");
  try {
    for (const utterance of sentences) {
      utterance.onerror = () => finished("Audio is unavailable. The full briefing is on this page.");
      speech.speak(utterance);
    }
  } catch {
    finished("Audio is unavailable. The full briefing is on this page.");
  }
}

window.addEventListener("pagehide",stopReading);

function notice(message) {
  const element = $("#notice");
  clearTimeout(noticeTimer);
  element.textContent = message;
  element.hidden = false;
  noticeTimer = setTimeout(()=>{ element.hidden = true; }, 5200);
}
function show(dialog) {
  if (!dialog.open) dialog.showModal();
}
function showBrief(queued) {
  if (!data) return;
  stopReading();
  queuedChoice = queued;
  transcript.value = data.state.transcript || data.catalog.intro?.transcript || data.catalog.intro || "";
  $("#start-button").textContent = data.state.started ? "Update my day" : "Build my day";
  voiceStatus.textContent = queued ? "Start your briefing to make choices for this trip." : "";
  $("#memory-profile").innerHTML = profileView(data.state.profile);
  show(brief);
}
function watchNavigation() {
  navObserver?.disconnect();
  if (!("IntersectionObserver" in window)) return;
  navObserver=new IntersectionObserver(entries=>{
    for (const entry of entries.filter(e=>e.isIntersecting)) {
      document.querySelectorAll("nav a").forEach(a=>{
        a.classList.toggle("nav-active",a.hash==="#"+entry.target.id);
        if (a.hash==="#"+entry.target.id) a.setAttribute("aria-current","location");
        else a.removeAttribute("aria-current");
      });
    }
  },{rootMargin:"0px 0px -70% 0px"});
  for(const id of ["day-plan","people","weekend"]) {const target=document.getElementById(id); if(target) navObserver.observe(target);}
}
function openedDetails() {
  return new Set([...content.querySelectorAll("details[open]")].map(el=>el.querySelector("summary")?.textContent));
}
function render(newData, preserve = true) {
  stopReading();
  clearTimeout(replayTimer);
  const prior = preserve ? openedDetails() : new Set();
  data = newData;
  content.innerHTML = dashboard(data,transitExpanded);
  content.querySelectorAll("details").forEach(el=>{
    if(prior.has(el.querySelector("summary")?.textContent)) el.open=true;
  });
  content.setAttribute("aria-busy","false");
  const hero = safeUrl(data.catalog.heroImage,true);
  if (hero) { $("#hero-photo").src = hero; $("#hero-photo-link").href = hero; }
  $("#hero-credit").innerHTML = credit(data.catalog.heroCredit);
  $("#brief-button span").textContent = data.state.started ? "Review trip briefing" : "Start trip briefing";
  $("#brief-button").disabled = false;
  if (data.state.alert === "shown" && !brief.open && !draftDialog.open) {
    $("#alert-content").innerHTML=alertView(data.catalog.alert);
    show(interruption);
  } else if(interruption.open && data.state.alert!=="shown") interruption.close();
  watchNavigation();
}
async function request(payload) {
  const options=payload ? {method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({...payload,revision:data.state.revision})} : {};
  const response=await fetch("/api/demo",{...options,cache:"no-store"});
  const result=await response.json().catch(()=>null);
  if (!response.ok) {
    const error = new Error(result?.error || "The trip service could not complete that request.");
    error.status = response.status;
    throw error;
  }
  if (!result?.state || !result?.catalog || !result?.tracker) throw new Error("The trip service returned an incomplete itinerary.");
  return result;
}
async function load() {
  try {render(await request(),false);}
  catch(error) {
    content.setAttribute("aria-busy","false");
    content.innerHTML=`<div class="error"><p>${esc(error.message)}</p><button type="button" class="btn secondary" id="retry">Retry loading</button></div>`;
  }
}
function draftText(action,id) {
  const dinner=data.catalog.dinner.find(opt=>opt.id===data.state.choices.dinner);
  const diningTime=data.tracker.lines.find(line=>line.title===dinner?.title)?.time || dinner?.time || "dinner";
  const contact=data.catalog.contacts.find(c=>c.id===id);
  if (action==="invite") {
    return {title:`Dinner invite for ${contact.name}`,text:`Hey ${contact.name.split(" ")[0]}, I’m going to ${dinner.title} at ${diningTime} after the hackathon. Want to join me? The address is ${dinner.address}.`};
  }
  const guests=(data.state.invitations || []).length+1;
  return {title:"Dinner reservation draft",text:`Table request for ${guests} at ${dinner.title}, ${data.catalog.date} at ${diningTime}. Dietary preferences: ${data.state.profile.diet}. Please confirm availability and whether the kitchen can accommodate these restrictions.`};
}
function showDraft(action,id) {
  const draft = draftText(action,id);
  $("#draft-title").textContent=draft.title;
  $("#draft-text").textContent=draft.text;
  $("#draft-status").textContent=action==="invite" ? "Draft only. No message has been sent." : "Draft only. No table has been booked.";
  show(draftDialog);
}
async function act(payload) {
  if (sending || !data) return;
  if (!data.state.started && !["start","reset"].includes(payload.action)) {
    showBrief(payload);
    return;
  }
  if (["invite","reserve"].includes(payload.action) && !data.state.confirmedSlots.includes("dinner")) {
    notice("Confirm a dinner choice to prepare your draft.");
    $("#slot-dinner")?.scrollIntoView();
    $("#select-dinner")?.focus({preventScroll:true});
    return;
  }
  if(payload.action==="alert" && !data.state.profile.discretion) {
    notice("The workplace interruption is available with the sample trip briefing.");
    return;
  }
  sending=true;
  content.setAttribute("aria-busy","true");
  $("#start-button").disabled=true;
  document.body.classList.add("pending");
  let next;
  try {
    const result=await request(payload);
    if(payload.action==="start") {
      next=queuedChoice; queuedChoice=null;
      if(brief.open) brief.close();
    }
    if(payload.action==="choose" && payload.slot === "transit") transitExpanded=false;
    if(payload.action==="reset") {transitExpanded=false; queuedChoice=null;}
    render(result,payload.action!=="reset");
    if(["invite","reserve"].includes(payload.action)) showDraft(payload.action,payload.id);
    if(payload.action==="reroute") {
      $("#slot-dinner")?.scrollIntoView();
      notice("Your dinner and evening route have been updated. Review the new dinner choice before preparing new drafts.");
    }
    if(payload.action==="dismiss") notice("Kept your original evening plan.");
    if(payload.action==="expense") notice("Expense added to your spending log.");
    if(payload.action==="reset") {window.scrollTo({top:0,behavior:"smooth"}); notice("Trip demo reset.");}
    if(payload.action==="choose" && data.state.alert!=="shown") notice("Trip choice saved. Your tracker is up to date.");
    if(payload.action==="start" && !next) {
      $("#day-plan")?.scrollIntoView();
      notice("Your briefing is saved. Choose how you’ll get there.");
    }
  } catch(error) {
    if(error.status===409) {
      try {render(await request());} catch { /* Keep the current plan while offline. */ }
    }
    if(brief.open) voiceStatus.textContent=error.message;
    else if(interruption.open) $("#alert-feedback").textContent=error.message;
    else notice(error.message);
    if(payload.action==="choose" && payload.slot!=="transit") {
      const select=document.getElementById("select-"+payload.slot);
      if(select && data.state.choices[payload.slot]) select.value=data.state.choices[payload.slot];
    }
  } finally {
    sending=false;
    document.body.classList.remove("pending");
    content.setAttribute("aria-busy","false");
    $("#start-button").disabled=false;
  }
  if(next) await act(next);
}
function beginVoice() {
  if(recognition) {recognition.stop(); return;}
  const Speech=window.SpeechRecognition || window.webkitSpeechRecognition;
  if(!Speech) {
    voiceStatus.textContent="Microphone transcription is unavailable in this browser. Edit the sample or type your briefing here.";
    transcript.focus();
    return;
  }
  const listener=new Speech();
  listener.continuous=true;
  listener.interimResults=true;
  listener.lang="en-US";
  listener.onstart=()=>{
    voiceButton.textContent="Stop listening";
    voiceStatus.textContent="Listening. Your words will replace the sample briefing.";
  };
  listener.onresult=event=>{
    transcript.value=Array.from(event.results).map(result=>result[0].transcript.trim()).join(" ").trim();
  };
  listener.onerror=event=>{
    voiceStatus.textContent=event.error==="not-allowed" ? "Microphone access was declined. Type your briefing or use the sample." : "Transcription paused. You can edit the briefing or use the microphone again.";
  };
  listener.onend=()=>{
    recognition=null;
    voiceButton.textContent="Use microphone";
    if(voiceStatus.textContent.startsWith("Listening")) voiceStatus.textContent="Review your briefing before building your day.";
  };
  recognition=listener;
  try {listener.start();}
  catch {recognition=null;voiceStatus.textContent="The microphone could not start. Type your briefing or use the sample.";}
}
async function recallMemory(form) {
  const status = $("#recall-status");
  const list = $("#recall-results");
  const button = form.querySelector("button");
  const fields = new FormData(form);
  const query = String(fields.get("query")).trim();
  if (!query) {status.textContent="Enter a word or question to search.";return;}
  list.replaceChildren();
  button.disabled = true;
  status.textContent = "Searching memory…";
  try {
    const response = await fetch("/api/recall", {
      method:"POST",
      headers:{"Content-Type":"application/json"},
      body:JSON.stringify({query,scope:fields.get("scope")})
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "Memory search is unavailable.");
    if (!Array.isArray(result.results)) throw new Error("Memory search returned an incomplete result.");
    for (const match of result.results) {
      const item=document.createElement("li");
      item.textContent=String(match);
      list.append(item);
    }
    const count=result.results.length;
    status.textContent=(count ? `${count} ${count===1 ? "match" : "matches"}. ` : "No matches. ") + (result.status || "");
  } catch(error) {status.textContent=error.message || "Memory search could not finish.";}
  finally {button.disabled=false;}
}
function replayCommute(button) {
  clearTimeout(replayTimer);
  const {catalog,state}=data;
  const breakfast=catalog.breakfast.find(option=>option.id===state.choices.breakfast) || catalog.breakfast[0];
  const stops=[
    {title:"Clement St & 14th Ave · public pickup",coords:catalog.originCoords},
    breakfast,
    {title:"AWS Builder Loft · 525 Market St",coords:catalog.event.coords}
  ];
  const box=$("#commute-replay");
  if(stops.some(stop=>!stop?.coords?.every(Number.isFinite))) {
    box.textContent="Coordinates are unavailable for this route.";
    return;
  }
  const longitudeScale = Math.cos(catalog.originCoords[0]*Math.PI/180);
  const projected = stops.map(stop=>[stop.coords[1]*longitudeScale,stop.coords[0]]);
  const xs=projected.map(p=>p[0]), ys=projected.map(p=>p[1]);
  const xMin=Math.min(...xs),yMin=Math.min(...ys);
  const xRange=Math.max(...xs)-xMin,yRange=Math.max(...ys)-yMin;
  const scale=Math.min(280/(xRange || 1e-8),72/(yRange || 1e-8));
  const points=projected.map(([x,y])=>[20+(280-scale*xRange)/2+(x-xMin)*scale,16+(72-scale*yRange)/2+(yMin+yRange-y)*scale]);
  button.disabled=true;
  function showStop(index) {
    const stop=stops[index], [mx,my]=points[index];
    const line=points.map(p=>p.join(",")).join(" ");
    box.innerHTML=`<svg class="commute-map" viewBox="0 0 320 104" aria-hidden="true">
      <polyline points="${line}" fill="none" stroke="#71879b" stroke-width="2" stroke-dasharray="4 3"/>
      ${points.map(([x,y])=>`<circle cx="${x}" cy="${y}" r="4" fill="#fff" stroke="#344b6b" stroke-width="2"/>`).join("")}
      <circle cx="${mx}" cy="${my}" r="10" fill="#ae4b2e" opacity=".2"/><circle cx="${mx}" cy="${my}" r="5" fill="#aa4029"/>
      </svg><p><strong>Simulated GPS · ${index+1} of 3</strong><br>${esc(stop.title)}<br><span class="subtle">${stop.coords.map(n=>n.toFixed(5)).join(", ")}</span></p>`;
    if(index < stops.length-1) replayTimer = setTimeout(()=>showStop(index+1),1800);
    else button.disabled=false;
  }
  showStop(0);
}
$("#brief-button").addEventListener("click",()=>showBrief());
voiceButton.addEventListener("click",beginVoice);
brief.addEventListener("close",()=>{recognition?.abort(); queuedChoice=null;});
$("#brief-form").addEventListener("submit",event=>{
  event.preventDefault();
  recognition?.stop();
  act({action:"start",transcript:transcript.value.trim()});
});
interruption.addEventListener("cancel",event=>{event.preventDefault();act({action:"dismiss"});});
document.addEventListener("change",event=>{
  const slot=event.target.dataset?.chooseSlot;
  if(slot) act({action:"choose",slot,id:event.target.value});
});
document.addEventListener("submit",event=>{
  if(event.target.id==="recall-form") {event.preventDefault();recallMemory(event.target);return;}
  if(event.target.id!=="expense-form") return;
  event.preventDefault();
  const fields=new FormData(event.target);
  act({action:"expense",label:String(fields.get("label")).trim(),amount:Number(fields.get("amount"))});
});
document.addEventListener("click",event=>{
  const button=event.target.closest("button");
  if(!button) return;
  if(button.id==="retry") {load();return;}
  if(button.id==="read-guide") {readGuide(button);return;}
  if(button.hasAttribute("data-commute")) {replayCommute(button);return;}
  if(button.dataset.close) {
    if(button.dataset.close==="alert-dialog") act({action:"dismiss"});
    else document.getElementById(button.dataset.close)?.close();
    return;
  }
  if(button.hasAttribute("data-reset")) {if(window.confirm("Clear this demo’s saved trip choices and drafts?")) act({action:"reset"});return;}
  if(button.hasAttribute("data-toggle-transit")) {transitExpanded=true;render(data);$("#transit button")?.focus({preventScroll:true});return;}
  const {action,slot,id}=button.dataset;
  if(action) act({action,...(slot ? {slot} : {}),...(id ? {id} : {})});
});
load();
