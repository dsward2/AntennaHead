



/*
function resizeContentFrame(aWindow) {
    console.log("resizeContentFrame");
    var contentFrameDiv = parent.document.getElementById("content_frame");
    var contentDiv = contentFrameDiv.children[0];
    contentDiv.style.visibility = 'hidden';
    contentDiv.style.height = "100px";
    var body = document.body;
    var html = document.documentElement;
    var height = Math.max( body.scrollHeight, body.offsetHeight, 
        html.clientHeight, html.scrollHeight, html.offsetHeight );
    contentDiv.style.height = (height + 100) + "px";
    contentDiv.style.top = 0;
    contentDiv.style.visibility = 'visible';
}
*/

// prevent zooming while using +/- buttons in frequency tuner pages
 document.addEventListener('touchmove', function(event) {
    event = event.originalEvent || event;
    if(event.scale > 1) {
      event.preventDefault();
    }
  }, false);

function handleEditCategoryClick(checkbox) {
    var checkboxState = checkbox.checked;
    var getUrl = window.location;
    //var baseUrl = getUrl .protocol + "//" + getUrl.host + "/" + getUrl.pathname.split('/')[1];
    var baseUrl = getUrl .protocol + "//" + getUrl.host + "/";
    
    var cat_id = checkbox.getAttribute("cat_id");
    var freq_id = checkbox.getAttribute("freq_id");
    
    var editUrl = baseUrl + "editcategoryitem.html?cat_id=" + cat_id + "&freq_id=" + freq_id + "&is_member=" + checkboxState;
  
    var xhttp = new XMLHttpRequest();
    xhttp.onreadystatechange = function() {
        if (this.readyState == 4 && this.status == 200) {
           // see xhttp.responseText;
        }
    };
    xhttp.open("GET", editUrl, true);
    xhttp.send();
}


function storeFrequencyRecord (form) {
  var formArray = $(form).serializeArray();
  var jsonData = JSON.stringify(formArray);

  var getUrl = window.location;
  var baseUrl = getUrl .protocol + "//" + getUrl.host + "/";
  var storeFrequencyUrl = baseUrl + "storefrequency.html";

  sendHTTPPostRequest("frequency", storeFrequencyUrl, jsonData, 1, true, true);
 
  return false;
};




function deleteFrequencyRecord (form) {
  var formArray = $(form).serializeArray();
  var jsonData = JSON.stringify(formArray);

  var getUrl = window.location;
  var baseUrl = getUrl .protocol + "//" + getUrl.host + "/";
  var deleteFrequencyUrl = baseUrl + "deletefrequency.html";

  var frequencyName = document.getElementById('frequency_name').value

  var r = confirm("Delete \""+frequencyName+"\" frequency?");
  if (r == true) {
    // OK button pressed
  } else {
    // Cancel button pressed
    return;
  }

  sendHTTPPostRequest("frequency", deleteFrequencyUrl, jsonData, 3, false, false);
  
  window.topButtonClicked(self);
}




function storeCategoryRecord (form) {
  var formArray = $(form).serializeArray();
  var jsonData = JSON.stringify(formArray);

  var getUrl = window.location;
  var baseUrl = getUrl .protocol + "//" + getUrl.host + "/";
  var storeCategoryUrl = baseUrl + "storecategory.html";


  sendHTTPPostRequest("category", storeCategoryUrl, jsonData, 1, true, true);
 
  return false;
};




function addCategoryRecord (form) {
  var newCategoryName = form.category_name.value;
  
  if (newCategoryName > "")
  {
      var formArray = $(form).serializeArray();
      var jsonData = JSON.stringify(formArray);

      var getUrl = window.location;
      var baseUrl = getUrl .protocol + "//" + getUrl.host + "/";
      var addCategoryUrl = baseUrl + "addcategory.html";

      sendHTTPPostRequest("category", addCategoryUrl, jsonData, 1, true, true);
  }
  else
  {
    alert("The Category Name is missing.  The new category record was not created.");
  }
 
  return false;
};


function deleteCategoryRecord (form) {
  var formArray = $(form).serializeArray();
  var jsonData = JSON.stringify(formArray);

  var getUrl = window.location;
  var baseUrl = getUrl .protocol + "//" + getUrl.host + "/";
  var deleteCategoryUrl = baseUrl + "deletecategory.html";

  var categoryName = document.getElementById('category_name').value

  var r = confirm("Delete \""+categoryName+"\" category?");
  if (r == true) {
    // OK button pressed
  } else {
    // Cancel button pressed
    return;
  }

  sendHTTPPostRequest("category", deleteCategoryUrl, jsonData, 2, false, false);
}





function insertNewFrequencyRecord (form) {
    var formArray = $(form).serializeArray();
    var jsonData = JSON.stringify(formArray);
    var validationResult = validateDataRecord("frequency", jsonData);
    if (validationResult == "OK")
    {
        var getUrl = window.location;
        var baseUrl = getUrl .protocol + "//" + getUrl.host + "/";
        var url = baseUrl + "insertnewfrequency.html";

        var xhttp = new XMLHttpRequest();
        xhttp.onreadystatechange = function() {
            if (this.readyState == 4 && this.status == 200) {
               // see xhttp.responseText;
               alert("Changes have been saved.");
               
               window.stop();
               window.backButtonClicked(self);
            }
        };
        xhttp.open("POST", url, true);
        xhttp.send(jsonData);
    }
    else
    {
        validationResult += " Changes were not saved.";
        alert(validationResult);
    }

    return false;
};


function setSampleRateInput(newSampleRate)
{
    var sampleRateInput = document.getElementById("sample_rate");
    sampleRateInput.value = newSampleRate;
}

function setScanSampleRateInput(newSampleRate)
{
    var sampleRateInput = document.getElementById("scan_sample_rate");
    sampleRateInput.value = newSampleRate;
}



// ---- Structured custom-task pipeline editor ----
// Markup here must mirror customTaskStageHTML() in AntennaHeadHTTPServer.swift.

function ctEsc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/'/g, '&#39;').replace(/"/g, '&quot;');
}

// Stops WebKit's smart quotes/dashes and autocorrect from mangling
// command-line text ("--text" would otherwise become an em dash).
var ctVerbatimAttrs = "autocomplete='off' autocorrect='off' autocapitalize='none' spellcheck='false'";

function customTaskArgRowHTML(v) {
  return "<div class='task-arg-row'><input class='task-arg' type='text' " + ctVerbatimAttrs + " value='" + ctEsc(v) + "' style='width:80%;'> "
    + "<input class='button' type='button' value='-' onclick='removeCustomTaskArgument(this);'></div>";
}

// Tool names for the stage editor's pop-up, provided by the server in the
// #task-stages data-tools attribute (bundled helpers + system tools).
function customTaskToolNames() {
  var c = document.getElementById('task-stages');
  var data = c ? c.getAttribute('data-tools') : '';
  return data ? data.split(',') : [];
}

function customTaskStageHTML(path, args) {
  if (!args || args.length === 0) { args = ['']; }
  var rows = '';
  for (var i = 0; i < args.length; i++) { rows += customTaskArgRowHTML(args[i]); }

  // A bare tool name selects that tool; a "/" path (or unknown name) uses the
  // Custom path text field.
  var tools = customTaskToolNames();
  var isKnown = path !== '' && path.indexOf('/') < 0 && tools.indexOf(path) >= 0;
  var selected = (path === '') ? (tools.length ? tools[0] : '__custom__')
                               : (isKnown ? path : '__custom__');
  var options = '';
  for (var t = 0; t < tools.length; t++) {
    options += "<option value='" + ctEsc(tools[t]) + "'" + (tools[t] === selected ? " selected" : "") + ">"
      + ctEsc(tools[t]) + "</option>";
  }
  options += "<option value='__custom__'" + (selected === '__custom__' ? " selected" : "") + ">Custom path…</option>";
  var pathStyle = (selected === '__custom__') ? "" : " style='display:none;'";

  return "<div class='task-stage' style='border:1px solid #bbb; border-radius:4px; padding:10px; margin-bottom:10px;'>"
    + "<a href='#pipeline-overview' class='ct-back-link' onclick='return scrollToPipelineOverview();'>↑ Pipeline overview</a>"
    + "<label>Tool</label>"
    + "<select class='task-tool u-full-width' onchange='customTaskToolChanged(this);'>" + options + "</select>"
    + "<input class='task-path u-full-width' type='text' " + ctVerbatimAttrs + " value='" + ctEsc(path) + "' placeholder='/path/to/tool'" + pathStyle + ">"
    + "<label>Arguments</label><div class='task-args'>" + rows + "</div>"
    + "<input class='button' type='button' value='+ Argument' onclick='addCustomTaskArgument(this);'> "
    + "<input class='button' type='button' value='+ Insert Stage Above' onclick='insertCustomTaskStageAbove(this);'> "
    + "<input class='button' type='button' value='Remove Stage' onclick='removeCustomTaskStage(this);'> "
    + "<input class='button' type='button' value='Copy Stage' onclick='copyCustomTaskStage(this);' "
    + "title='Copy this stage as CLI text'> "
    + "<input class='button' type='button' value='Paste Stage' onclick='pasteCustomTaskStage(this);' "
    + "title='Replace this stage from CLI text on the clipboard'>"
    + "</div>";
}

function addCustomTaskStage() {
  var c = document.getElementById('task-stages');
  if (c) { c.insertAdjacentHTML('beforeend', customTaskStageHTML('', [''])); }
  buildCustomTaskPipelineOverview();
}

function removeCustomTaskStage(btn) {
  var st = btn.closest('.task-stage');
  if (st) { st.parentNode.removeChild(st); }
  buildCustomTaskPipelineOverview();
}

// Tool pop-up changed: reveal the custom-path field only for "Custom path…"
// and refresh the graphical overview's stage names.
function customTaskToolChanged(sel) {
  var st = sel.closest('.task-stage');
  var pathEl = st ? st.querySelector('.task-path') : null;
  if (pathEl) { pathEl.style.display = (sel.value === '__custom__') ? '' : 'none'; }
  buildCustomTaskPipelineOverview();
}

// Effective executable for a stage: the selected tool name, or the custom path.
function customTaskStagePath(stageEl) {
  var sel = stageEl.querySelector('.task-tool');
  if (sel && sel.value !== '__custom__') { return sel.value; }
  var pathEl = stageEl.querySelector('.task-path');
  return pathEl ? pathEl.value.trim() : '';
}

// Inserts an empty stage directly above this one, so a new intermediate stage
// can be added anywhere in the pipeline (Add Stage only appends at the end).
function insertCustomTaskStageAbove(btn) {
  var st = btn.closest('.task-stage');
  if (st) { st.insertAdjacentHTML('beforebegin', customTaskStageHTML('', [''])); }
  buildCustomTaskPipelineOverview();
}

function addCustomTaskArgument(btn) {
  var st = btn.closest('.task-stage');
  if (!st) { return; }
  var args = st.querySelector('.task-args');
  if (args) { args.insertAdjacentHTML('beforeend', customTaskArgRowHTML('')); }
}

function removeCustomTaskArgument(btn) {
  var row = btn.closest('.task-arg-row');
  if (row) { row.parentNode.removeChild(row); }
}


// ---- Custom-task pipeline graphical overview (index) ----
// Mirrors the SwiftUI Status view's SVG flow diagram. Acts as an index to the
// stage editors below: clicking a node scrolls to that stage. Rebuilt whenever
// a stage is added, removed, or its executable path is edited.

function ctStageName(path) {
  var p = String(path == null ? '' : path).trim();
  if (p.length === 0) { return '(empty)'; }
  var parts = p.split('/');
  var name = parts[parts.length - 1] || p;
  if (name.length > 18) { name = name.slice(0, 17) + '…'; }
  return name;
}

function buildCustomTaskPipelineOverview() {
  var host = document.getElementById('pipeline-overview-graphic');
  if (!host) { return; }
  var stageEls = document.querySelectorAll('#task-stages .task-stage');
  var names = [];
  for (var i = 0; i < stageEls.length; i++) {
    // Give each stage a stable anchor id so nodes can scroll to it.
    stageEls[i].id = 'task-stage-' + i;
    names.push(ctStageName(customTaskStagePath(stageEls[i])));
  }
  if (!names.length) {
    host.innerHTML = "<p class='ct-idle'>No pipeline stages yet — add a stage below.</p>";
    return;
  }
  var NW = 150, NH = 54, GAP = 46, PADX = 12, TOP = 22, BOT = 12;
  var W = PADX * 2 + names.length * NW + (names.length - 1) * GAP;
  var H = TOP + NH + BOT;
  var p = "<svg viewBox='0 0 " + W + " " + H + "' width='" + W + "' height='" + H + "' xmlns='http://www.w3.org/2000/svg'>";
  p += "<defs><marker id='ctah' markerWidth='9' markerHeight='9' refX='7' refY='3' orient='auto'><path d='M0,0 L7,3 L0,6 Z' class='ct-arrowhead'/></marker></defs>";
  for (var j = 0; j < names.length; j++) {
    var x = PADX + j * (NW + GAP);
    var y = TOP;
    var midY = y + NH / 2;
    if (j > 0) {
      var x1 = x - GAP, x2 = x;
      p += "<line x1='" + x1 + "' y1='" + midY + "' x2='" + (x2 - 3) + "' y2='" + midY + "' class='ct-arrow' marker-end='url(#ctah)'/>";
      p += "<text x='" + ((x1 + x2) / 2) + "' y='" + (midY - 6) + "' class='ct-link-label' text-anchor='middle'>pipe</text>";
    }
    p += "<g class='ct-pnode' onclick='scrollToCustomTaskStage(" + j + ");'>";
    p += "<rect x='" + x + "' y='" + y + "' width='" + NW + "' height='" + NH + "' rx='10' class='ct-node'/>";
    p += "<text x='" + (x + 14) + "' y='" + (y + 22) + "' class='ct-node-index'>Stage " + (j + 1) + "</text>";
    p += "<text x='" + (x + 14) + "' y='" + (y + 42) + "' class='ct-node-name'>" + ctEsc(names[j]) + "</text>";
    p += "</g>";
  }
  p += "</svg>";
  host.innerHTML = p;
}

function scrollToCustomTaskStage(i) {
  var el = document.getElementById('task-stage-' + i);
  if (el) { el.scrollIntoView({ behavior: 'smooth', block: 'start' }); }
  return false;
}

function scrollToPipelineOverview() {
  var el = document.getElementById('pipeline-overview');
  if (el) { el.scrollIntoView({ behavior: 'smooth', block: 'start' }); }
  return false;
}

// Called by loadContent() after the Edit Custom Task fragment is injected.
// (Inline <script> in the fragment won't run, since it's set via innerHTML.)
function initCustomTaskEditor() {
  var stages = document.getElementById('task-stages');
  if (stages) {
    // Delegated listener: refresh the overview names as paths are typed.
    stages.addEventListener('input', function (e) {
      if (e.target && e.target.classList && e.target.classList.contains('task-path')) {
        buildCustomTaskPipelineOverview();
      }
    });
  }
  buildCustomTaskPipelineOverview();
}

function buildCustomTaskJSON() {
  var tasks = [];
  var stages = document.querySelectorAll('#task-stages .task-stage');
  for (var i = 0; i < stages.length; i++) {
    var path = customTaskStagePath(stages[i]);
    if (path.length === 0) { continue; }
    var args = [];
    var argEls = stages[i].querySelectorAll('.task-arg');
    for (var j = 0; j < argEls.length; j++) {
      if (argEls[j].value.length > 0) { args.push(argEls[j].value); }
    }
    tasks.push({ path: path, arguments: args });
  }
  return JSON.stringify({ tasks: tasks });
}


// ---- Copy/paste a stage (or the whole pipeline) as CLI text ----
// The quoting and `|`-splitting rules live once, server-side, in
// PipelineHelpers' CLIStageText (shared with ControlBooth); these two
// endpoints are thin wrappers around it, so this file only gathers/rebuilds
// DOM state and never re-implements the parsing itself.

// Clipboard access needs a secure context (https, or localhost); fall back to
// a prompt dialog everywhere else so Copy/Paste still work over plain http.
function ctCopyText(text) {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).catch(function () { window.prompt('Copy this text:', text); });
  } else {
    window.prompt('Copy this text:', text);
  }
}

function ctPasteText(callback) {
  if (navigator.clipboard && navigator.clipboard.readText) {
    navigator.clipboard.readText().then(callback).catch(function () {
      var text = window.prompt('Paste CLI text:');
      if (text !== null) { callback(text); }
    });
  } else {
    var text = window.prompt('Paste CLI text:');
    if (text !== null) { callback(text); }
  }
}

function ctExportTasks(tasks, callback) {
  var xhttp = new XMLHttpRequest();
  xhttp.onreadystatechange = function () {
    if (xhttp.readyState === 4 && xhttp.status === 200) { callback(xhttp.responseText); }
  };
  xhttp.open('POST', 'customtaskpipelinetotext.html', true);
  xhttp.setRequestHeader('Content-Type', 'application/json');
  xhttp.send(JSON.stringify({ tasks: tasks }));
}

function ctImportText(text, callback) {
  var xhttp = new XMLHttpRequest();
  xhttp.onreadystatechange = function () {
    if (xhttp.readyState === 4 && xhttp.status === 200) {
      var tasks = [];
      try { tasks = (JSON.parse(xhttp.responseText).tasks) || []; } catch (e) {}
      callback(tasks);
    }
  };
  xhttp.open('POST', 'customtasktexttopipeline.html', true);
  xhttp.setRequestHeader('Content-Type', 'text/plain');
  xhttp.send(text);
}

function ctStageTasks(stageEl) {
  var args = [];
  var argEls = stageEl.querySelectorAll('.task-arg');
  for (var j = 0; j < argEls.length; j++) {
    if (argEls[j].value.length > 0) { args.push(argEls[j].value); }
  }
  return { path: customTaskStagePath(stageEl), arguments: args };
}

function copyCustomTaskStage(btn) {
  var st = btn.closest('.task-stage');
  if (!st) { return; }
  ctExportTasks([ctStageTasks(st)], ctCopyText);
}

// Pasted text may itself be a whole `|`-joined pipeline (e.g. copied from
// ControlBooth's own Copy Pipeline); every resulting stage replaces this one
// slot in order, so pasting a multi-stage pipeline into one slot still works.
function pasteCustomTaskStage(btn) {
  var st = btn.closest('.task-stage');
  if (!st) { return; }
  ctPasteText(function (text) {
    ctImportText(text, function (tasks) {
      if (!tasks.length) { return; }
      var html = '';
      for (var i = 0; i < tasks.length; i++) { html += customTaskStageHTML(tasks[i].path, tasks[i].arguments); }
      st.insertAdjacentHTML('beforebegin', html);
      st.parentNode.removeChild(st);
      buildCustomTaskPipelineOverview();
    });
  });
}

function copyCustomTaskPipeline() {
  var tasks = JSON.parse(buildCustomTaskJSON()).tasks;
  ctExportTasks(tasks, ctCopyText);
}

function pasteCustomTaskPipeline() {
  ctPasteText(function (text) {
    ctImportText(text, function (tasks) {
      var c = document.getElementById('task-stages');
      if (!c) { return; }
      if (!tasks.length) { tasks = [{ path: '', arguments: [''] }]; }
      var html = '';
      for (var i = 0; i < tasks.length; i++) { html += customTaskStageHTML(tasks[i].path, tasks[i].arguments); }
      c.innerHTML = html;
      buildCustomTaskPipelineOverview();
    });
  });
}


function storeCustomTaskRecord (form) {
  var hidden = document.getElementById('task_json_hidden');
  if (hidden) { hidden.value = buildCustomTaskJSON(); }

  var formArray = $(form).serializeArray();
  var jsonData = JSON.stringify(formArray);

  var getUrl = window.location;
  var baseUrl = getUrl.protocol + "//" + getUrl.host + "/";

  sendHTTPPostRequest("custom_task", baseUrl + "storecustomtask.html", jsonData, 1, false, true);

  return false;
}


// Listen button on the Edit Custom Task page. The server builds the pipeline
// from the stored record, so save the current edits first, then start listening
// (same request customTaskListenButtonClicked sends from the Devices page).
function editCustomTaskListenButtonClicked (form, taskID) {
  var hidden = document.getElementById('task_json_hidden');
  if (hidden) { hidden.value = buildCustomTaskJSON(); }

  var formArray = $(form).serializeArray();
  var jsonData = JSON.stringify(formArray);

  var getUrl = window.location;
  var baseUrl = getUrl.protocol + "//" + getUrl.host + "/";

  var storeRequest = new XMLHttpRequest();
  storeRequest.onreadystatechange = function() {
    if (this.readyState == 4 && this.status == 200) {
      // Edits saved — now start the custom-task pipeline.
      var listenData = JSON.stringify([{ name: "custom_task_select", value: String(taskID) }]);
      var listenRequest = new XMLHttpRequest();
      listenRequest.open("POST", baseUrl + "customtasklistenbuttonclicked.html", true);
      listenRequest.send(listenData);

      // handle the audio tag with the new source
      window.top.postMessage("startaudio", "*");
    }
  };
  storeRequest.open("POST", baseUrl + "storecustomtask.html", true);
  storeRequest.send(jsonData);

  return false;
}


function deleteCustomTaskRecord (form) {
  var formArray = $(form).serializeArray();
  var jsonData = JSON.stringify(formArray);

  var getUrl = window.location;
  var baseUrl = getUrl.protocol + "//" + getUrl.host + "/";

  var taskName = form.task_name ? form.task_name.value : "";
  if (confirm("Delete \"" + taskName + "\" custom task?") != true) {
    return false;
  }

  sendHTTPPostRequest("custom_task", baseUrl + "deletecustomtask.html", jsonData, 1, false, false);

  return false;
}


function sendHTTPPostRequest (table, url, jsonData, backCount, validateData, showAlert) {
    var validationResult = "OK";
    if (validateData == true)
    {
        validationResult = validateDataRecord(table, jsonData);
    }
    if (validationResult == "OK")
    {
        var xhttp = new XMLHttpRequest();
        xhttp.onreadystatechange = function() {
            if (this.readyState == 4 && this.status == 200) {
               // see xhttp.responseText;
               if (showAlert == true)
               {
                    alert("Changes have been saved.");
               }
               
               if (backCount > 0)
               {
                    window.stop();

                    if (backCount == 1)
                    {
                        window.backButtonClicked();
                    }
                    else
                    {
                        window.topButtonClicked();
                    }
               }
            }
        };
        xhttp.open("POST", url, true);
        xhttp.send(jsonData);
    }
    else
    {
        validationResult += " Changes were not saved.";
        alert(validationResult);
    }
};


function validateDataRecord(table, jsonData)
{
    var result = "OK";
    
    if (table == "frequency")
    {
        result = validateFrequencyRecord(jsonData);
    }
    else if (table == "category")
    {
        result = validateFrequencyRecord(jsonData);
    }
    
    return result;
}



function validateFrequencyRecord(jsonData)
{
    var result = "OK";

    try
    {
        var obj = JSON.parse(jsonData);

        var frequencyRecord = [];

        for (var i = 0, len = obj.length; i < len; i++) {
            var aName = obj[i].name;
            var aValue = obj[i].value;
            
            frequencyRecord[aName] = aValue;
        }

        var station_name = frequencyRecord["station_name"];
        if (station_name == "")
        {
            return "Station Name is missing.";
        }

        var frequency = frequencyRecord["frequency"];
        if ((frequency == "") || (frequency == 0))
        {
            return "Frequency is missing or zero.";
        }

        var frequencyMode = frequencyRecord["frequency_mode"];
        if (frequencyMode == "frequency_mode_single")
        {
        }
        else if (frequencyMode == "frequency_mode_range")
        {
            var frequencyScanEnd = frequencyRecord["frequency_scan_end"];
            if ((frequencyScanEnd == "") || (frequencyScanEnd <= 0))
            {
                return "Frequency Scan End is missing or zero.  A valid end frequency is required when using Frequency Range scanner mode.";
            }

            var frequencyScanInterval = frequencyRecord["frequency_scan_interval"];
            if ((frequencyScanInterval == "") || (frequencyScanInterval <= 0))
            {
                return "Frequency Scan Interval is missing or zero.  A valid interval is required when using Frequency Range scanner mode.";
            }
        }

        var sampleRate = frequencyRecord["sample_rate"];
        if ((sampleRate == "") || (sampleRate == 0))
        {
            return "Sample Rate is missing or zero.";
        }

      
    } catch (ex) {
      //console.error(ex);
      console.log(ex);
    }
    
    return result;
}



function validateCategoryRecord(jsonData)
{
    var result = "OK";
    
    return result;
}




var frequency_min = 0;
var frequency_max = 1766000000; // 1.766 GHz


function tunerDigitClicked(element)
{
    //console.log("tunerDigitClicked: " + element.id);
    
    var tunerDigitsDiv = document.getElementById("tuner-digits")
    var tunerDigitsArray = document.getElementsByClassName("tuner-digit");
    var i;
    for (i = 0; i < tunerDigitsArray.length; i++) {
        tunerDigitsArray[i].style.backgroundColor = "white";
        tunerDigitsArray[i].selected = false;
    }
    
    element.style.backgroundColor = "lightgray";
    element.selected = true;
}




function frequencyUpButtonClicked(element)
{
    //console.log("frequencyUpButtonClicked: " + element.id);
    
    var selectedDigit = -1;
    
    var tunerDigitsDiv = document.getElementById("tuner-digits")
    var tunerDigitsArray = document.getElementsByClassName("tuner-digit");
    var i;
    for (i = 0; i < tunerDigitsArray.length; i++) {
        if (tunerDigitsArray[i].selected == true)
        {
            selectedDigit = tunerDigitsArray[i];
            
            var digitID = selectedDigit.id;
            
            /*
            var digitText = selectedDigit.innerText;
            digitText = Number(digitText) + 1;
            
            if (digitText > 9)
            {
                digitText = 9;
            }

            selectedDigit.innerText = digitText;
            */
            
            var increment = 1;
            
            switch (digitID) {
                case "XXXX-MHz":
                    increment = 1000000000;
                    break;
                case "XXX-MHz":
                    increment = 100000000;
                    break;
                case "XX-MHz":
                    increment = 10000000;
                    break;
                case "X-MHz":
                    increment = 1000000;
                    break;
                case "X-KHz":
                    increment = 100000;
                    break;
                case "XX-KHz":
                    increment = 10000;
                    break;
                case "XXX-KHz":
                    increment = 1000;
                    break;
                case "XXXX-KHz":
                    increment = 100;
                    break;
                case "XXXXX-KHz":
                    increment = 10;
                    break;
                case "XXXXXX-KHz":
                    increment = 1;
                    break;
            }
            

            var xxxxMHz = Number(document.getElementById("XXXX-MHz").innerText);
            var xxxMHz = Number(document.getElementById("XXX-MHz").innerText);
            var xxMHz = Number(document.getElementById("XX-MHz").innerText);
            var xMHz = Number(document.getElementById("X-MHz").innerText);
            var xKHz = Number(document.getElementById("X-KHz").innerText);
            var xxKHz = Number(document.getElementById("XX-KHz").innerText);
            var xxxKHz = Number(document.getElementById("XXX-KHz").innerText);
            var xxxxKHz = Number(document.getElementById("XXXX-KHz").innerText);
            var xxxxxKHz = Number(document.getElementById("XXXXX-KHz").innerText);
            var xxxxxxKHz = Number(document.getElementById("XXXXXX-KHz").innerText);
            
            var oldFrequency = (
                    (xxxxMHz *  1000000000) +
                    (xxxMHz *   100000000) +
                    (xxMHz *    10000000) +
                    (xMHz *     1000000) +
                    (xKHz *     100000) +
                    (xxKHz *    10000) +
                    (xxxKHz *   1000) +
                    (xxxxKHz *  100) +
                    (xxxxxKHz * 10) +
                     xxxxxxKHz);
            
            if ((oldFrequency >= 87500000) && (oldFrequency <= 107900000))
            {
                if (digitID == "X-KHz")
                {
                    if (xKHz % 2 == 1)
                    {
                        increment = 200000;  // special rule for FM broadcast - odd values only for 100x KHz
                    }
                }
            }

            var newFrequency = oldFrequency + increment;
            
            setFrequencyDigits(newFrequency);
            
            break;
        }
    }
    
    checkFrequencyRange();
    
    updateFrequencyInput();
}


function frequencyDownButtonClicked(element)
{
    //console.log("frequencyDownButtonClicked: " + element.id);
    
    var selectedDigit = -1;
    
    var tunerDigitsDiv = document.getElementById("tuner-digits")
    var tunerDigitsArray = document.getElementsByClassName("tuner-digit");
    var i;
    for (i = 0; i < tunerDigitsArray.length; i++) {
        if (tunerDigitsArray[i].selected == true)
        {
            selectedDigit = tunerDigitsArray[i];

            var digitID = selectedDigit.id;

            /*
            var digitText = selectedDigit.innerText;
            digitText = Number(digitText) - 1;
            
            if (digitText < 0)
            {
              digitText = 0;
            }
            
            selectedDigit.innerText = digitText;
            */

            var increment = 1;
            
            switch (digitID) {
                case "XXXX-MHz":
                    increment = 1000000000;
                    break;
                case "XXX-MHz":
                    increment = 100000000;
                    break;
                case "XX-MHz":
                    increment = 10000000;
                    break;
                case "X-MHz":
                    increment = 1000000;
                    break;
                case "X-KHz":
                    increment = 100000;
                    break;
                case "XX-KHz":
                    increment = 10000;
                    break;
                case "XXX-KHz":
                    increment = 1000;
                    break;
                case "XXXX-KHz":
                    increment = 100;
                    break;
                case "XXXXX-KHz":
                    increment = 10;
                    break;
                case "XXXXXX-KHz":
                    increment = 1;
                    break;
            }
            
            var xxxxMHz = Number(document.getElementById("XXXX-MHz").innerText);
            var xxxMHz = Number(document.getElementById("XXX-MHz").innerText);
            var xxMHz = Number(document.getElementById("XX-MHz").innerText);
            var xMHz = Number(document.getElementById("X-MHz").innerText);
            var xKHz = Number(document.getElementById("X-KHz").innerText);
            var xxKHz = Number(document.getElementById("XX-KHz").innerText);
            var xxxKHz = Number(document.getElementById("XXX-KHz").innerText);
            var xxxxKHz = Number(document.getElementById("XXXX-KHz").innerText);
            var xxxxxKHz = Number(document.getElementById("XXXXX-KHz").innerText);
            var xxxxxxKHz = Number(document.getElementById("XXXXXX-KHz").innerText);
            
            var oldFrequency = (
                    (xxxxMHz *  1000000000) +
                    (xxxMHz *   100000000) +
                    (xxMHz *    10000000) +
                    (xMHz *     1000000) +
                    (xKHz *     100000) +
                    (xxKHz *    10000) +
                    (xxxKHz *   1000) +
                    (xxxxKHz *  100) +
                    (xxxxxKHz * 10) +
                     xxxxxxKHz);

            if ((oldFrequency >= 87500000) && (oldFrequency <= 107900000))
            {
                if (digitID == "X-KHz")
                {
                    if (xKHz % 2 == 1)
                    {
                        increment = 200000;  // special rule for FM broadcast - odd values only for 100x KHz
                    }
                }
            }

            var newFrequency = oldFrequency - increment;
            
            setFrequencyDigits(newFrequency);

            break;
        }
    }
    
    checkFrequencyRange();
    
    updateFrequencyInput();
}



function updateFrequencyInput()
{
    var xxxxMHz = Number(document.getElementById("XXXX-MHz").innerText);
    var xxxMHz = Number(document.getElementById("XXX-MHz").innerText);
    var xxMHz = Number(document.getElementById("XX-MHz").innerText);
    var xMHz = Number(document.getElementById("X-MHz").innerText);
    var xKHz = Number(document.getElementById("X-KHz").innerText);
    var xxKHz = Number(document.getElementById("XX-KHz").innerText);
    var xxxKHz = Number(document.getElementById("XXX-KHz").innerText);
    var xxxxKHz = Number(document.getElementById("XXXX-KHz").innerText);
    var xxxxxKHz = Number(document.getElementById("XXXXX-KHz").innerText);
    var xxxxxxKHz = Number(document.getElementById("XXXXXX-KHz").innerText);
    
    var newFrequency = (
            (xxxxMHz *  1000000000) +
            (xxxMHz *   100000000) +
            (xxMHz *    10000000) +
            (xMHz *     1000000) +
            (xKHz *     100000) +
            (xxKHz *    10000) +
            (xxxKHz *   1000) +
            (xxxxKHz *  100) +
            (xxxxxKHz * 10) +
             xxxxxxKHz);
    
    document.getElementById("frequency").value = newFrequency;
}


function checkFrequencyRange()
{
    var tunerDigitsDiv = document.getElementById("tuner-digits")
    
    var tunerDigitsArray = document.getElementsByClassName("tuner-digit");
    
    var frequency =
            tunerDigitsArray[0].innerText +
            tunerDigitsArray[1].innerText +
            tunerDigitsArray[2].innerText +
            tunerDigitsArray[3].innerText +
            tunerDigitsArray[4].innerText +
            tunerDigitsArray[5].innerText +
            tunerDigitsArray[6].innerText +
            tunerDigitsArray[7].innerText +
            tunerDigitsArray[8].innerText +
            tunerDigitsArray[9].innerText;
    
    frequency = Number(frequency);
    
    if (frequency < frequency_min)
    {
        setFrequencyDigits(frequency_min);
    }
    else if (frequency > frequency_max)
    {
        setFrequencyDigits(frequency_max);
    }
}


function setFrequencyDigits(frequency)
{
  //console.log("setFrequencyDigits - frequency "+frequency);
  newFrequency = "00000000000" + frequency;
  frequencyLength = newFrequency.length;
  newFrequency = newFrequency.substring(frequencyLength - 10);
  //console.log("setFrequencyDigits - frequency trimmed "+newFrequency);
  
  var tunerDigitsDiv = document.getElementById("tuner-digits")
  var tunerDigitsArray = document.getElementsByClassName("tuner-digit");
  var i;
  for (i = 0; i < 10; i++) {
    tunerDigitsArray[i].innerText = newFrequency[i];
  }

  /*
  var utterance  = new SpeechSynthesisUtterance();
  var newFrequencyFloat = newFrequency / 1000000;
  //utterance.rate = 1.5;
  utterance.text = newFrequencyFloat;
  speechSynthesis.speak(utterance);
  */
}



function listenButtonClicked(form)
{
  //console.log("listenButtonClicked");
  
  var formArray = $(form).serializeArray();
  var jsonData = JSON.stringify(formArray);

  // request to HTTP server to set radio tuning
  var getUrl = window.location;
  var baseUrl = getUrl .protocol + "//" + getUrl.host + "/";
  var listenButtonClickedUrl = baseUrl + "listenbuttonclicked.html";

  var xhttp = new XMLHttpRequest();
  xhttp.onreadystatechange = function() {
      if (this.readyState == 4 && this.status == 200) {
        // response received ok
        window.top.nowPlayingTitle = window.document.getElementById("listen_title");
      }
    };
  xhttp.open("POST", listenButtonClickedUrl, true);
  xhttp.send(jsonData);

  // handle the audio tag with the new source
  window.top.postMessage("startaudio", "*");

  //console.log("postMessage startaudio");
}




function frequencyListenButtonClicked()
{
  //console.log("frequencyListenButtonClicked");

    var tunerDigitsDiv = document.getElementById("tuner-digits")
    
    var tunerDigitsArray = document.getElementsByClassName("tuner-digit");
    
    var frequency =
            tunerDigitsArray[0].innerText +
            tunerDigitsArray[1].innerText +
            tunerDigitsArray[2].innerText +
            tunerDigitsArray[3].innerText +
            tunerDigitsArray[4].innerText +
            tunerDigitsArray[5].innerText +
            tunerDigitsArray[6].innerText +
            tunerDigitsArray[7].innerText +
            tunerDigitsArray[8].innerText +
            tunerDigitsArray[9].innerText;

    var sampleRateSelect = document.getElementById("sample_rate");
    var sampleRateOptions = sampleRateSelect.children;
    var sampleRateIndex = sampleRateSelect.selectedIndex;
    var sampleRateSelectedOption = sampleRateOptions[sampleRateIndex];
    var sample_rate = sampleRateSelectedOption.value;

    var tunerGainSelect = document.getElementById("tuner_gain");
    var tunerGainOptions = tunerGainSelect.children;
    var tunerGainIndex = tunerGainSelect.selectedIndex;
    var tunerGainSelectedOption = tunerGainOptions[tunerGainIndex];
    var tuner_gain = tunerGainSelectedOption.value;

    var stereo_flag = false;
    var stereoFlagSelect = document.getElementById("stereo_flag");
    if (stereoFlagSelect !== null)
    {
        var stereoFlagOptions = stereoFlagSelect.children;
        var stereoFlagIndex = stereoFlagSelect.selectedIndex;
        var tunerGainSelectedOption = stereoFlagOptions[stereoFlagIndex];
        stereo_flag = tunerGainSelectedOption.value;
    }

    // Modulation is page-specific (WBFM/narrowband = fm, AM/aviation = am).
    // Inline <script> can't run (pages are injected via innerHTML), so each
    // tuner page carries a hidden #tuner_modulation element we read here.
    var modulation = 'fm';
    var modulationElem = document.getElementById('tuner_modulation');
    if (modulationElem !== null) { modulation = modulationElem.value; }

    var tuningArray = {frequency:frequency, sample_rate: sample_rate, tuner_gain: tuner_gain, stereo_flag: stereo_flag, modulation: modulation};

    var jsonData = JSON.stringify(tuningArray);

    // request to HTTP server to set radio tuning
    var getUrl = window.location;
    var baseUrl = getUrl .protocol + "//" + getUrl.host + "/";
    var frequencyListenButtonClickedUrl = baseUrl + "frequencylistenbuttonclicked.html";

    var xhttp = new XMLHttpRequest();
    xhttp.onreadystatechange = function() {
      //console.log("readyState="+this.readyState+", status="+this.status);
      if (this.readyState == 4 && this.status == 200) {
        // response received ok
        window.top.nowPlayingTitle = window.document.getElementById("listen_title");
      }
    };
    xhttp.open("POST", frequencyListenButtonClickedUrl, true);
    xhttp.send(jsonData);

    // handle the audio tag with the new source
    window.top.postMessage("startaudio", "*");

    //console.log("postMessage startaudio");
}


// Listen for the Advanced tuner form, which has plain named fields (no
// tuner-digit widget). Reads the form's values and posts the same JSON object
// the frequencylistenbuttonclicked.html route expects.
function advancedListenButtonClicked(form)
{
    var fieldValue = function(name) {
        var element = form.elements[name];
        return element ? element.value : '';
    };
    var tuningArray = {
        frequency: fieldValue('frequency'),
        sample_rate: fieldValue('sample_rate'),
        tuner_gain: fieldValue('tuner_gain'),
        stereo_flag: fieldValue('stereo_flag'),
        modulation: fieldValue('modulation')
    };
    var jsonData = JSON.stringify(tuningArray);

    var getUrl = window.location;
    var baseUrl = getUrl.protocol + "//" + getUrl.host + "/";

    var xhttp = new XMLHttpRequest();
    xhttp.onreadystatechange = function() {
        if (this.readyState == 4 && this.status == 200) {
            window.top.nowPlayingTitle = window.document.getElementById("listen_title");
        }
    };
    xhttp.open("POST", baseUrl + "frequencylistenbuttonclicked.html", true);
    xhttp.send(jsonData);

    window.top.postMessage("startaudio", "*");

    return false;
}






function scannerListenButtonClicked(form)
{
  //console.log("listenButtonClicked");
  
  var formArray = $(form).serializeArray();
  var jsonData = JSON.stringify(formArray);

  // request to HTTP server to set radio tuning
  var getUrl = window.location;
  var baseUrl = getUrl .protocol + "//" + getUrl.host + "/";
  var scannerListenButtonClickedUrl = baseUrl + "scannerlistenbuttonclicked.html";

  var xhttp = new XMLHttpRequest();
  xhttp.onreadystatechange = function() {
      if (this.readyState == 4 && this.status == 200) {
        // response received ok
        window.top.nowPlayingTitle = window.document.getElementById("listen_title");
      }
    };
  xhttp.open("POST", scannerListenButtonClickedUrl, true);
  xhttp.send(jsonData);

  // handle the audio tag with the new source
  window.top.postMessage("startaudio", "*");

  //console.log("postMessage startaudio");
}



function deviceListenButtonClicked(form)
{
  //console.log("deviceListenButtonClicked");
  
  var formArray = $(form).serializeArray();
  var jsonData = JSON.stringify(formArray);

  // request to HTTP server to set audio input device
  var getUrl = window.location;
  var baseUrl = getUrl .protocol + "//" + getUrl.host + "/";
  var listenButtonClickedUrl = baseUrl + "devicelistenbuttonclicked.html";

  var xhttp = new XMLHttpRequest();
  xhttp.onreadystatechange = function() {
      if (this.readyState == 4 && this.status == 200) {
        // response received ok
        window.top.nowPlayingTitle = window.document.getElementById("listen_title");
      }
    };
  xhttp.open("POST", listenButtonClickedUrl, true);
  xhttp.send(jsonData);

  // handle the audio tag with the new source
  window.top.postMessage("startaudio", "*");

  //console.log("postMessage startaudio");
}


function customTaskListenButtonClicked(form)
{
  //console.log("deviceListenButtonClicked");
  
  var formArray = $(form).serializeArray();
  var jsonData = JSON.stringify(formArray);

  // request to HTTP server to set audio input device
  var getUrl = window.location;
  var baseUrl = getUrl .protocol + "//" + getUrl.host + "/";
  var listenButtonClickedUrl = baseUrl + "customtasklistenbuttonclicked.html";

  var xhttp = new XMLHttpRequest();
  xhttp.onreadystatechange = function() {
      if (this.readyState == 4 && this.status == 200) {
        // response received ok
        window.top.nowPlayingTitle = window.document.getElementById("listen_title");
      }
    };
  xhttp.open("POST", listenButtonClickedUrl, true);
  xhttp.send(jsonData);

  // handle the audio tag with the new source
  window.top.postMessage("startaudio", "*");

  //console.log("postMessage startaudio");
}


function controlBoothListenButtonClicked(form)
{
  var formArray = $(form).serializeArray();
  var jsonData = JSON.stringify(formArray);

  var getUrl = window.location;
  var baseUrl = getUrl.protocol + "//" + getUrl.host + "/";
  var listenButtonClickedUrl = baseUrl + "controlboothlistenbuttonclicked.html";

  var xhttp = new XMLHttpRequest();
  xhttp.onreadystatechange = function() {
      if (this.readyState == 4 && this.status == 200) {
        window.top.nowPlayingTitle = window.document.getElementById("listen_title");
      }
    };
  xhttp.open("POST", listenButtonClickedUrl, true);
  xhttp.send(jsonData);

  window.top.postMessage("startaudio", "*");
}


//var displayUpdateInterval = 5000;  // five seconds
var displayUpdateInterval = 0;  // fast updates
var currentInterval = 0;
var pollingInterval = 250;  // four times per second

function periodicUpdate()
{
  //console.log("periodicUpdate");
  
    if (currentInterval >= displayUpdateInterval)
    {
      // request to HTTP server to get radio status
      var getUrl = window.location;
      var baseUrl = getUrl .protocol + "//" + getUrl.host + "/";
      var nowPlayingStatusUrl = baseUrl + "nowplayingstatus.html";

      var xhttp = new XMLHttpRequest();
      xhttp.onreadystatechange = function() {
        if (this.readyState == 4 && this.status == 200) {
          // response received ok
          updateStatusDisplay(xhttp.response);
        }
      };
      xhttp.open("POST", nowPlayingStatusUrl, true);
      xhttp.send();
    }
    
    currentInterval = currentInterval + pollingInterval;
    
    if (currentInterval >= displayUpdateInterval)
    {
        currentInterval = 0;
    }
}

// Printing description of statusData:
// {"modulation":"fm","oversampling":4,"signal_level":19,"options":"","frequency_scan_interval":0,"tuner_gain":49.7,"station_name":"KUAR-NPR Little Rock 89.1","atan_math":"std","sampling_mode":0,"sample_rate":85000,"frequency_mode":0,"squelch_level":0,"id":4,"tuner_agc":1,"frequency_scan_end":0,"fir_size":9,"audio_output_filter":"vol 1","frequency":89100000}
function updateStatusDisplay(statusData)
{
    var statusObj = "";

    try {
      statusObj = JSON.parse(statusData);
    }
    catch(err) {
      return;
    }

    var rtlsdr_task_mode = statusObj.rtlsdr_task_mode;
    
    var audio_output_filter = statusObj.audio_output_filter;
    var atan_math = statusObj.atan_math;
    var bias_t_flag = statusObj.bias_t_flag;
    var fir_size = statusObj.fir_size;
    var frequency = statusObj.frequency;
    var frequency_mode = statusObj.frequency_mode;
    var frequency_scan_end = statusObj.frequency_scan_end;
    var frequency_scan_interval = statusObj.frequency_scan_interval;
    var modulation = statusObj.modulation;
    var options = statusObj.options;
    var oversampling = statusObj.oversampling;
    var sample_rate = statusObj.sample_rate;
    var sampling_mode = statusObj.sampling_mode;
    var short_frequency = statusObj.short_frequency;
    var signal_level = statusObj.signal_level;
    var squelch_level = statusObj.squelch_level;
    var stereo_flag = statusObj.stereo_flag;
    var station_name = statusObj.station_name;
    var tuner_agc = statusObj.tuner_agc;
    var tuner_gain = statusObj.tuner_gain;
    var usb_device_string = statusObj.usb_device_string;
    
    if (rtlsdr_task_mode == "frequency")
    {
        var nowPlayingName = document.getElementById("now-playing-name");
        if (nowPlayingName != null)
        {
            nowPlayingName.innerHTML = station_name;
        }
    }

    if (rtlsdr_task_mode == "scan")
    {
        audio_output_filter = statusObj.scan_audio_output_filter;
        atan_math = statusObj.scan_atan_math;
        bias_t_flag = statusObj.scan_bias_t_flag;
        fir_size = statusObj.scan_fir_size;
        frequency_mode = statusObj.scan_frequency_mode;
        modulation = statusObj.scan_modulation;
        options = statusObj.scan_options;
        oversampling = statusObj.scan_oversampling;
        sample_rate = statusObj.scan_sample_rate;
        sampling_mode = statusObj.scan_sampling_mode;
        squelch_level = statusObj.scan_squelch_level;
        tuner_agc = statusObj.scan_tuner_agc;
        tuner_gain = statusObj.scan_tuner_gain;
        usb_device_string - statusObj.scan_usb_device_string;
    }
    
    var nowPlayingDetails = document.getElementById("now-playing-details");
    if (nowPlayingDetails != null)
    {
        var statusHtml = "<div style=\"position: relative;\">";
        statusHtml += "<br><br>";

        
        if (rtlsdr_task_mode == "scan")
        {
          statusHtml += "<span id='now-playing-details' style='overflow-x: scroll; white-space: nowrap;'>";

          statusHtml += "name: ";
          statusHtml += station_name;
          statusHtml += "<br>";
          
          statusHtml += "</span>"
        }
        
        statusHtml += "frequency: ";
        statusHtml += short_frequency;
        statusHtml += "<br>";
        statusHtml += "signal level: ";
        statusHtml += signal_level;
        statusHtml += "<br>";

        if (rtlsdr_task_mode == "scan")
        {
          statusHtml += "<br><br>CATEGORY SCANNER SETTINGS: <br>";
        }
        
        statusHtml += "squelch level: ";
        statusHtml += squelch_level;
        statusHtml += "<br>";
        statusHtml += "modulation: ";
        statusHtml += modulation;
        statusHtml += "<br>";
        statusHtml += "sample rate: ";
        statusHtml += sample_rate;
        statusHtml += "<br>";
        statusHtml += "sampling mode: ";
        statusHtml += sampling_mode;
        statusHtml += "<br>";
        statusHtml += "oversampling: ";
        statusHtml += oversampling;
        statusHtml += "<br>";
        statusHtml += "tuner gain: ";
        statusHtml += tuner_gain;
        statusHtml += "<br>";
        statusHtml += "tuner agc: ";
        statusHtml += tuner_agc;
        statusHtml += "<br>";
        statusHtml += "rtl-sdr options: pad ";
        statusHtml += options;
        statusHtml += "<br>";
        statusHtml += "fir size: ";
        statusHtml += fir_size;
        statusHtml += "<br>";
        statusHtml += "atan math: ";
        statusHtml += atan_math;
        statusHtml += "<br>";
        statusHtml += "audio output filter: rate 48000 ";
        statusHtml += audio_output_filter;
        statusHtml += "<br>";
        statusHtml += "bias-t: ";
        statusHtml += bias_t_flag;
        statusHtml += "<br>";
        statusHtml += "usb device: ";
        statusHtml += usb_device_string;
        statusHtml += "<br>";
        statusHtml += "<div>";

        nowPlayingDetails.innerHTML = statusHtml;
    }
    
    window.top.nowPlayingTitle = station_name;

    var nowPlayingNavBarLink = window.top.document.getElementById("nowPlayingNavBarLink");
    nowPlayingNavBarLink.innerText = "NOW PLAYING: " + station_name;
}

var intervalID = setInterval(function(){periodicUpdate();}, 20000);     // for Now Playing periodic updates using setInterval()

function startNowPlayingUpdates()
{
    clearInterval(intervalID);

    intervalID = setInterval(function(){periodicUpdate();}, pollingInterval);   // fast updates
}


function stopNowPlayingUpdates()
{
    clearInterval(intervalID);

    intervalID = setInterval(function(){periodicUpdate();}, 20000);    // update every 20 seconds
}


function applyAACSettings(form)
{
  //console.log("frequencyListenButtonClicked");

    var bitrateSelect = document.getElementById("bitrate_select");
    var bitrateOptions = bitrateSelect.children;
    var bitrateIndex = bitrateSelect.selectedIndex;
    var bitrateSelectedOption = bitrateOptions[bitrateIndex];
    var bitrate = bitrateSelectedOption.value;

    var aacSettingsArray = {bitrate: bitrate};

    var jsonData = JSON.stringify(aacSettingsArray);

    // request to HTTP server to set radio tuning
    var getUrl = window.location;
    var baseUrl = getUrl .protocol + "//" + getUrl.host + "/";
    var applyAACSettingsButtonClickedUrl = baseUrl + "applyaacsettings.html";

    var xhttp = new XMLHttpRequest();
    xhttp.onreadystatechange = function() {
      //console.log("readyState="+this.readyState+", status="+this.status);
      if (this.readyState == 4 && this.status == 200) {
        // response received ok
        alert("The AAC streaming settings were changed, and the servers are restarting.  Press the ► Play button to start audio.")
      }
    };
    xhttp.open("POST", applyAACSettingsButtonClickedUrl, true);
    xhttp.send(jsonData);

    // handle the audio tag with the new source
    //window.top.postMessage("startaudio", "*");

    //console.log("postMessage startaudio");
}


// AAC recorder toggle (button + elapsed-time span next to the <audio>
// element — see AntennaHeadHTTPServer.aacRecorderToggleHTML()). Talks to
// this server's own /api/aac-recorder/* routes, which drive
// LiveAudioServerProcessManager.startRecording(at:)/stopRecording() so the
// recording lands in the shared App Group Recordings folder.

var aacRecorderStartedAt = null;       // Date the current recording began, from the server
var aacRecorderTickIntervalID = null;  // ticks the elapsed-time display once/sec while recording

function aacRecorderBaseUrl()
{
    var getUrl = window.location;
    return getUrl.protocol + "//" + getUrl.host + "/";
}

function aacRecorderToggle()
{
    var btn = document.getElementById("aac-rec-btn");
    if (btn && btn.classList.contains("recording"))
    {
        aacRecorderStop();
    }
    else
    {
        aacRecorderStart();
    }
}

function aacRecorderStart()
{
    var xhttp = new XMLHttpRequest();
    xhttp.onreadystatechange = function() {
        if (this.readyState == 4) {
            if (this.status == 200) {
                applyAACRecorderStatus(JSON.parse(this.responseText));
            } else {
                alert("Couldn't start AAC recording (HTTP " + this.status + ")");
            }
        }
    };
    xhttp.open("POST", aacRecorderBaseUrl() + "api/aac-recorder/start", true);
    xhttp.send();
}

function aacRecorderStop()
{
    var xhttp = new XMLHttpRequest();
    xhttp.onreadystatechange = function() {
        if (this.readyState == 4) {
            if (this.status == 200) {
                applyAACRecorderStatus(JSON.parse(this.responseText));
            } else {
                alert("Couldn't stop AAC recording (HTTP " + this.status + ")");
            }
        }
    };
    xhttp.open("POST", aacRecorderBaseUrl() + "api/aac-recorder/stop", true);
    xhttp.send();
}

function aacRecorderPoll()
{
    var xhttp = new XMLHttpRequest();
    xhttp.onreadystatechange = function() {
        if (this.readyState == 4 && this.status == 200) {
            applyAACRecorderStatus(JSON.parse(this.responseText));
        }
    };
    xhttp.open("GET", aacRecorderBaseUrl() + "api/aac-recorder/status", true);
    xhttp.send();
}

function aacRecorderFormatElapsed(seconds)
{
    seconds = Math.max(0, Math.floor(seconds));
    var m = Math.floor(seconds / 60);
    var s = seconds % 60;
    return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s;
}

function applyAACRecorderStatus(status)
{
    var btn = document.getElementById("aac-rec-btn");
    var timeEl = document.getElementById("aac-rec-time");
    if (!btn || !timeEl) return;

    if (status && status.recording)
    {
        btn.classList.add("recording");
        btn.title = "Stop AAC recording";
        aacRecorderStartedAt = status.startedAt ? new Date(status.startedAt) : new Date();
        timeEl.style.display = "";
        if (!aacRecorderTickIntervalID)
        {
            aacRecorderTickIntervalID = setInterval(aacRecorderTick, 1000);
        }
        aacRecorderTick();
    }
    else
    {
        btn.classList.remove("recording");
        btn.title = "Record the AAC stream to a file";
        timeEl.style.display = "none";
        timeEl.textContent = "00:00";
        aacRecorderStartedAt = null;
        if (aacRecorderTickIntervalID)
        {
            clearInterval(aacRecorderTickIntervalID);
            aacRecorderTickIntervalID = null;
        }
    }
}

function aacRecorderTick()
{
    var timeEl = document.getElementById("aac-rec-time");
    if (!timeEl || !aacRecorderStartedAt) return;
    var elapsed = (Date.now() - aacRecorderStartedAt.getTime()) / 1000;
    timeEl.textContent = aacRecorderFormatElapsed(elapsed);
}

// Poll every 5s so the toggle stays in sync even when the recording was
// started/stopped elsewhere (ControlBooth, the LiveAudioServer status tab).
// The first real check happens from bodyElementLoaded()'s one-shot timeout
// below (mirrors the Now Playing periodicUpdate() pattern) — this script
// runs in <head>, before #aac-rec-btn exists in the DOM.
var aacRecorderPollIntervalID = setInterval(aacRecorderPoll, 5000);

