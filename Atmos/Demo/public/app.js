import { alertView, briefingView, dashboard, detailsFor, esc, menuPhotoFor, messageApproval, profileView, routeSection, routeSlots, updateClock } from "./views.js";

import { isTravelSlot, routeFor, routeMap } from "./route-map.js";

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
// Open on the option menus, including any choices already saved on this trip.
let sectionEdits = Object.fromEntries(routeSlots.map(slot=>[slot,null]));
let noticeTimer;
let recognition;
const detailDialog = $("#detail-dialog");
let mapSlot = isTravelSlot(history.state?.mapSlot) ? history.state.mapSlot : "transit";
let replayFrame;
let activeReading;
let threadOpen = false;
let sendingMessageId;
let deliveryTimer;

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
function showBrief() {
  if (!data) return;
  stopReading();
  transcript.value = data.state.transcript || data.catalog.intro?.transcript || data.catalog.intro || "";
  $("#start-button").textContent = data.state.started ? "Update my day" : "Build my day";
  voiceStatus.textContent = "";
  $("#memory-profile").innerHTML = briefingView(data) + profileView(data.state.profile);
  show(brief);
}
function openDetail(view) {
  if (!view) return;
  $("#detail-title").textContent = view.title;
  $("#detail-content").innerHTML = view.body;
  show(detailDialog);
  if (detailDialog.querySelector("[data-route-slot]")) drawMaps(detailDialog);
}

function focusMap(slot) {
  mapSlot=slot;
  history.replaceState({...history.state,mapSlot},"");
}
function currentMapRoute(slot=mapSlot) {
  return routeFor(data,slot,sectionEdits[slot]);
}
function drawMaps(root=content) {
  for (const element of root.querySelectorAll("[data-route-slot]")) {
    const slot=element.dataset.routeSlot;
    const {width,height}=element.getBoundingClientRect();
    if (!width || !height) continue;
    element.innerHTML=routeMap(currentMapRoute(slot==="active" ? mapSlot : slot),width,height,element.classList.contains("basemap"));
  }
}
let resizeFrame;
window.addEventListener("resize",()=>{
  cancelAnimationFrame(resizeFrame);
  resizeFrame=requestAnimationFrame(()=>{
    drawMaps();
    if (detailDialog.open) drawMaps(detailDialog);
  });
});
function openedDetails() {
  return new Set([...content.querySelectorAll("details[open]")].map(el=>el.querySelector("summary")?.textContent));
}
function showHome(prompt = "", error = "") {
  history.replaceState(history.state,"","/");
  $(".skip").hidden = true;
  content.replaceChildren($("#home-template").content.cloneNode(true));
  content.setAttribute("aria-busy","false");
  $("#home-prompt").value = prompt;
  $("#home-status").textContent = error;
  $("#resume-trip").hidden = !data.state.started;
  if (error) $("#home-prompt").focus();
}
async function showPlanning(pendingTrip) {
  history.replaceState(history.state,"","/?view=trip");
  $(".skip").hidden = true;
  content.replaceChildren($("#planning-template").content.cloneNode(true));
  // Keep the live status readable while the request is pending.
  content.setAttribute("aria-busy","false");
  $("#planning-title").focus({preventScroll:true});
  const status = $("#planning-status");
  status.textContent = "Reading your trip briefing…";
  const beat = window.matchMedia("(prefers-reduced-motion: reduce)").matches ? 300 : 950;
  const stopsTimer = setTimeout(() => { status.textContent = "Connecting your stops…"; }, beat);
  const timesTimer = setTimeout(() => { status.textContent = "Estimating travel times…"; }, 2 * beat);
  let revealTimer;
  const transition = new Promise(resolve => { revealTimer = setTimeout(resolve, 3 * beat); });
  try {
    const [trip] = await Promise.all([pendingTrip, transition]);
    return trip;
  } finally {
    clearTimeout(stopsTimer);
    clearTimeout(timesTimer);
    clearTimeout(revealTimer);
  }
}
function render(newData, preserve = true) {
  stopReading();
  cancelAnimationFrame(replayFrame);
  const prior = preserve ? openedDetails() : new Set();
  data = newData;
  if (!data.state.started) {
    if (interruption.open) interruption.close();
    showHome();
    return;
  }
  const revealing = Boolean($("#planning-status"));
  $(".skip").hidden = false;
  content.innerHTML = dashboard(data,sectionEdits,{open:threadOpen,sendingId:sendingMessageId});
  drawMaps();
  content.querySelectorAll("details").forEach(el=>{
    if(prior.has(el.querySelector("summary")?.textContent)) el.open=true;
  });
  content.setAttribute("aria-busy","false");
  updateClock();
  if (revealing) {
    const locationTitle = $("#location-title");
    locationTitle.tabIndex = -1;
    locationTitle.focus({preventScroll:true});
    window.scrollTo(0,0);
  }
  if (data.state.alert === "shown" && !brief.open && !draftDialog.open) {
    $("#alert-content").innerHTML=alertView(data.catalog.alert);
    show(interruption);
  } else if(interruption.open && data.state.alert!=="shown") interruption.close();

}
function sectionElement(slot) {
  return document.getElementById(slot==="transit" ? "transit" : "slot-"+slot);
}
function editSection(slot,id) {
  if (sending) return;
  const oldId = sectionEdits[slot] || data.state.choices[slot];
  sectionEdits[slot] = id;
  sectionElement(slot).outerHTML = routeSection(data,slot,id);
  if (isTravelSlot(slot)) { focusMap(slot); drawMaps(); }
  const section = sectionElement(slot);
  const focus = id ? section.querySelector('[data-action="choose"]') :
    [...section.querySelectorAll("[data-preview]")].find(button=>button.dataset.preview===oldId) || section.querySelector("[data-preview]");
  focus?.focus({preventScroll:true});
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
  try {
    data = await request();
    const url = new URL(window.location.href);
    const handoff = url.hash === "#planning";
    const resume = url.searchParams.get("view") === "trip" || url.hash === "#day-plan";
    if (!data.state.started || !(handoff || resume)) {
      showHome();
      return;
    }
    if (handoff) await showPlanning(data);
    render(data,false);
  }
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
  if(payload.action==="alert" && data.state.started && !data.state.profile.discretion) {
    notice("The workplace interruption is available with the sample trip briefing.");
    return;
  }
  sending=true;
  content.setAttribute("aria-busy","true");
  $("#start-button").disabled=true;
  document.body.classList.add("pending");
  const fromHome = payload.action === "start" && Boolean($("#home-form"));
  try {
    const pendingTrip = request(payload);
    const result = await (fromHome ? showPlanning(pendingTrip) : pendingTrip);
    if (detailDialog.open) detailDialog.close();
    if (payload.action === "sendDinnerText") {
      threadOpen = true;
      const message = result.state.sentDinnerTexts.find(m=>m.key===payload.key);
      if (message) {
        clearTimeout(deliveryTimer);
        sendingMessageId = message.id;
        deliveryTimer = setTimeout(()=>{
          sendingMessageId = undefined;
          const status = $("#group-thread .message-new .delivery");
          if (status) status.textContent = "Delivered";
          status?.closest("li")?.classList.remove("message-new");
        },1150);
      }
    }
    if(payload.action==="start") {
      if(brief.open) brief.close();
    }
    if (payload.action==="choose" || payload.action==="skip") {
      delete sectionEdits[payload.slot];
      if (isTravelSlot(payload.slot)) focusMap(payload.slot);
      else if (payload.slot==="breakfast") focusMap("transit");
      else if (payload.slot==="dinner") focusMap(payload.action==="skip" ? "toNightlife" : "toDinner");
      else if (payload.slot==="nightlife") focusMap("toNightlife");
    }
    if (payload.action==="reroute") {
      delete sectionEdits.dinner;
      focusMap("toDinner");
    }
    if (payload.action==="reset") focusMap("transit");
    if(payload.action==="reset") {sectionEdits={}; threadOpen=false; clearTimeout(deliveryTimer); sendingMessageId=undefined;}
    render(result,payload.action!=="reset");
    if(payload.action==="choose" && !interruption.open) {
      sectionElement(payload.slot)?.querySelector("[data-options]")?.focus({preventScroll:true});
      if (payload.slot==="lunch") openDetail(detailsFor(data,"lunchPosts"));
    }
    if(["invite","reserve"].includes(payload.action)) showDraft(payload.action,payload.id);
    if(payload.action==="sendDinnerText") focusConversation();
    if(payload.action==="reroute") {
      $("#slot-dinner")?.scrollIntoView();
      notice("Your dinner and evening route have been updated. Review the new dinner choice before preparing new drafts.");
    }
    if(payload.action==="dismiss") {
      if (sectionEdits.nightlife==="afterhours") sectionElement("nightlife")?.querySelector('[data-action="choose"]')?.focus({preventScroll:true});
      notice("Kept your original evening plan.");
    }
    if(payload.action==="expense") notice("Expense added to your spending log.");
    if(payload.action==="reset") {window.scrollTo({top:0,behavior:"smooth"}); notice("Trip demo reset.");}
    if(payload.action==="skip") notice("Stop removed from your route.");
    if(payload.action==="choose" && data.state.alert!=="shown") notice("Route updated.");
    if(payload.action==="start") {
      notice("Your briefing is saved. Choose how you’ll get there.");
    }
  } catch(error) {
    if(error.status===409) {
      try {
        data = await request();
        if (!fromHome) render(data);
      } catch { /* Keep the current plan while offline. */ }
    }
    if (payload.action !== "start") render(data);
    if (fromHome) {
      showHome(payload.transcript,error.message);
      return;
    }
    if (detailDialog.open && payload.action==="sendDinnerText") {
      if (data.dinnerTextDraft) {
        openDetail({title:"Dinner invitation",body:messageApproval(data.dinnerTextDraft)});
        $("#approval-status").textContent = error.message;
      } else { detailDialog.close(); notice(error.message); }
    }
    else if(brief.open) voiceStatus.textContent=error.message;
    else if(interruption.open) $("#alert-feedback").textContent=error.message;
    else notice(error.message);
  } finally {
    sending=false;
    document.body.classList.remove("pending");
    content.setAttribute("aria-busy","false");
    $("#start-button").disabled=false;
  }

}
function beginVoice(field,button,status) {
  if(recognition) {recognition.stop(); return;}
  const Speech=window.SpeechRecognition || window.webkitSpeechRecognition;
  if(!Speech) {
    status.textContent="Microphone transcription is unavailable in this browser. Type or paste your briefing here.";
    field.focus();
    return;
  }
  function micLabel(listening) {
    const label = listening ? "Stop listening" : "Use microphone";
    button.setAttribute("aria-label",label);
    button.setAttribute("aria-pressed",String(listening));
    button.title = label;
    const caption = button === voiceButton ? button : button.querySelector("[data-mic-label]");
    if (caption) caption.textContent = label;
  }
  const listener=new Speech();
  listener.continuous=true;
  listener.interimResults=true;
  listener.lang="en-US";
  listener.onstart=()=>{
    micLabel(true);
    status.textContent="Listening. Your words will replace the text in the briefing.";
  };
  listener.onresult=event=>{
    field.value=Array.from(event.results).map(result=>result[0].transcript.trim()).join(" ").trim();
  };
  listener.onerror=event=>{
    status.textContent=event.error==="not-allowed" ? "Microphone access was declined. Type or paste your briefing." : "Transcription paused. You can edit the briefing or use the microphone again.";
  };
  listener.onend=()=>{
    if (recognition === listener) recognition=null;
    micLabel(false);
    if(status.textContent.startsWith("Listening")) status.textContent="Review your briefing before building your day.";
  };
  recognition=listener;
  try {listener.start();}
  catch {recognition=null;status.textContent="The microphone could not start. Type or paste your briefing.";}
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
  cancelAnimationFrame(replayFrame);
  const route=currentMapRoute();
  const status=$("#commute-replay");
  const duration=window.matchMedia("(prefers-reduced-motion: reduce)").matches ? 0 : 3600;
  const start=performance.now();
  button.disabled=true;
  status.textContent="Simulated GPS · "+route.stops.map(s=>s.label).join(" → ");
  function step(now) {
    if (!detailDialog.open || !button.isConnected) return;
    const path=detailDialog.querySelector("[data-replay-path]");
    const marker=detailDialog.querySelector("[data-gps-marker]");
    if (!path || !marker) { button.disabled=false; return; }
    const progress=duration ? Math.min(1,(now-start)/duration) : 1;
    const at=path.getPointAtLength(path.getTotalLength()*progress);
    marker.setAttribute("cx",at.x);
    marker.setAttribute("cy",at.y);
    marker.setAttribute("visibility","visible");
    if (progress<1) replayFrame=requestAnimationFrame(step);
    else {
      const stop=route.stops.at(-1);
      status.textContent="Simulated GPS · Arrived at "+stop.label+" · "+stop.coords.map(n=>n.toFixed(5)).join(", ");
      button.disabled=false;
    }
  }
  replayFrame=requestAnimationFrame(step);
}
function focusConversation() {
  const panel = $("#group-thread");
  if (!panel) return;
  panel.focus({preventScroll:true});
  panel.scrollIntoView({block:"nearest"});
  const messages = panel.querySelector(".messages");
  const outgoing = messages.querySelector(".message-new");
  if (outgoing) outgoing.scrollIntoView({block:"nearest"});
  else messages.scrollTop = messages.scrollHeight;
}
setInterval(updateClock, 15000);
detailDialog.addEventListener("close",()=>cancelAnimationFrame(replayFrame));
voiceButton.addEventListener("click",()=>beginVoice(transcript,voiceButton,voiceStatus));
brief.addEventListener("close",()=>{recognition?.abort(); stopReading();});
$("#brief-form").addEventListener("submit",event=>{
  event.preventDefault();
  recognition?.stop();
  act({action:"start",transcript:transcript.value.trim()});
});
interruption.addEventListener("cancel",event=>{event.preventDefault();act({action:"dismiss"});});
document.addEventListener("submit",event=>{
  if (event.target.id === "home-form") {
    event.preventDefault();
    const field = $("#home-prompt");
    const prompt = field.value.trim();
    if (!prompt) {
      $("#home-status").textContent = "Enter your trip briefing to plan your day.";
      field.focus();
      return;
    }
    recognition?.stop();
    act({action:"start", transcript:prompt});
    return;
  }
  if(event.target.id==="recall-form") {event.preventDefault();recallMemory(event.target);return;}
  if(event.target.id!=="expense-form") return;
  event.preventDefault();
  const fields=new FormData(event.target);
  act({action:"expense",label:String(fields.get("label")).trim(),amount:Number(fields.get("amount"))});
});
document.addEventListener("click",event=>{
  const button=event.target.closest("button");
  if(!button) return;
  if(button.id==="home-mic") {beginVoice($("#home-prompt"),button,$("#home-status"));return;}
  if(button.id==="brief-button") {showBrief();return;}
  if(button.hasAttribute("data-preview")) {
    const {slot,preview} = button.dataset;
    if (sending) return;
    editSection(slot,preview);
    if (slot==="nightlife" && preview==="afterhours" && data.state.profile.discretion) {
      act({action:"previewNightlife",id:preview});
    }
    return;
  }
  if(button.hasAttribute("data-options")) {editSection(button.dataset.options,null);return;}
  if(button.hasAttribute("data-pick-dinner")) {
    if (detailDialog.open) detailDialog.close();
    editSection("dinner",null);
    sectionElement("dinner").scrollIntoView({block:"center"});
    return;
  }
  if(button.hasAttribute("data-group-invite")) {
    const draft = data.dinnerTextDraft;
    if (!draft) {notice("Include dinner to invite Gio and Andrew.");return;}
    openDetail({title:"Dinner invitation",body:messageApproval(draft)});
    return;
  }
  if(button.hasAttribute("data-approve-text")) {
    act({action:"sendDinnerText",key:button.dataset.key});
    return;
  }
  if(button.hasAttribute("data-show-messages") || button.hasAttribute("data-hide-messages")) {
    threadOpen = button.hasAttribute("data-show-messages");
    render(data);
    if (threadOpen) focusConversation();
    else $("[data-show-messages]")?.focus({preventScroll:true});
    return;
  }
  if(button.hasAttribute("data-detail")) {
    const kind=button.dataset.detail;
    openDetail(detailsFor(data,kind,button.dataset.person || button.dataset.itemId,kind==="map" ? currentMapRoute() : undefined));
    return;
  }
  if(button.hasAttribute("data-photo-slot")) {
    openDetail(menuPhotoFor(data,button.dataset.photoSlot,button.dataset.photoId,Number(button.dataset.photoIndex)));
    return;
  }
  if(button.id==="retry") {load();return;}
  if(button.id==="read-guide") {readGuide(button);return;}
  if(button.hasAttribute("data-commute")) {replayCommute(button);return;}
  if(button.dataset.close) {
    if(button.dataset.close==="alert-dialog") act({action:"dismiss"});
    else document.getElementById(button.dataset.close)?.close();
    return;
  }
  if(button.hasAttribute("data-reset")) {if(window.confirm("Clear this demo’s saved trip choices and drafts?")) act({action:"reset"});return;}
  const {action,slot,id}=button.dataset;
  if(action) act({action,...(slot ? {slot} : {}),...(id ? {id} : {})});
});
load();
