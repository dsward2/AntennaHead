



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
        tunerDigitsArray[i].classList.remove("tuner-digit-selected");
        tunerDigitsArray[i].selected = false;
    }

    element.classList.add("tuner-digit-selected");
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


// --- Keyboard support for the tuner-digit frequency widget -----------------
//
// Called from loadContent() after every page injection; a no-op on pages
// that have no <div class="tuner-digits"> widget. Makes each visible digit
// focusable (tabindex=0) so Tab / Shift-Tab step through the digits and on
// to the next field the way they do for text inputs, and wires:
//
//   0-9              write that digit, then advance to the next digit
//   Backspace        reset the digit to 0 and step back one digit
//   Delete           reset the digit to 0, stay put
//   ArrowLeft/Right  move the selection to the adjacent digit
//   ArrowUp/Down     increment / decrement (same as the on-screen +/- buttons)
//
// Editing reuses the existing helpers (tunerDigitClicked, checkFrequencyRange,
// updateFrequencyInput), so range clamping and the hidden #frequency field
// stay in sync exactly as they do for mouse users.
function initTunerDigitKeyboard()
{
    var widget = document.getElementsByClassName("tuner-digits")[0];
    if (!widget) { return; }

    // Visible, editable digits in left-to-right (document) order. The widget
    // always carries all ten <span class="tuner-digit"> cells; the ones that
    // don't apply to the current band are hidden with .tuner-digit-hidden.
    function editableDigits()
    {
        var cells = widget.getElementsByClassName("tuner-digit");
        var list = [];
        for (var i = 0; i < cells.length; i++)
        {
            if (!cells[i].classList.contains("tuner-digit-hidden"))
            {
                list.push(cells[i]);
            }
        }
        return list;
    }

    function setDigit(cell, text)
    {
        tunerDigitClicked(cell);
        cell.innerText = text;
        checkFrequencyRange();
        updateFrequencyInput();
    }

    var digits = editableDigits();
    for (var d = 0; d < digits.length; d++)
    {
        var digit = digits[d];
        digit.setAttribute("tabindex", "0");
        digit.setAttribute("role", "spinbutton");

        // Focusing a digit (via Tab, or a click) selects it, so the +/-
        // buttons and ArrowUp/Down act on whatever the keyboard last landed on.
        digit.addEventListener("focus", function () { tunerDigitClicked(this); });

        digit.addEventListener("keydown", function (event) {
            // Leave browser/OS shortcuts (Cmd-R, Ctrl-L, ...) untouched.
            if (event.ctrlKey || event.metaKey || event.altKey) { return; }

            var list = editableDigits();
            var index = list.indexOf(this);
            if (index < 0) { return; }

            // Plain digit key: overwrite this cell and jump to the next one.
            if (event.key.length === 1 && event.key >= "0" && event.key <= "9")
            {
                event.preventDefault();
                setDigit(this, event.key);
                if (list[index + 1]) { list[index + 1].focus(); }
                return;
            }

            switch (event.key)
            {
                case "Backspace":
                    event.preventDefault();
                    setDigit(this, "0");
                    if (list[index - 1]) { list[index - 1].focus(); }
                    break;

                case "Delete":
                    event.preventDefault();
                    setDigit(this, "0");
                    break;

                case "ArrowLeft":
                    event.preventDefault();
                    if (list[index - 1]) { list[index - 1].focus(); }
                    break;

                case "ArrowRight":
                    event.preventDefault();
                    if (list[index + 1]) { list[index + 1].focus(); }
                    break;

                case "ArrowUp":
                    event.preventDefault();
                    tunerDigitClicked(this);
                    frequencyUpButtonClicked(this);
                    break;

                case "ArrowDown":
                    event.preventDefault();
                    tunerDigitClicked(this);
                    frequencyDownButtonClicked(this);
                    break;

                // Tab / Shift-Tab: left alone so the browser moves focus to
                // the next/previous digit, then on to the next field natively.
            }
        });
    }
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


// Fills in the "USB Device" combo box's <datalist id="usb_device_datalist">
// (there's at most one per loaded page) with the RTL-SDR devices currently
// connected, so the field's dropdown offers real 8-digit serial numbers
// while still accepting freely typed text. Called from loadContent() after
// every page load; a no-op when the loaded page has no such field.
function populateUSBDeviceDatalist()
{
    var datalist = document.getElementById('usb_device_datalist');
    if (datalist === null) { return; }

    var getUrl = window.location;
    var baseUrl = getUrl.protocol + "//" + getUrl.host + "/";
    var url = baseUrl + "rtlsdrdevices.html";

    var xhttp = new XMLHttpRequest();
    xhttp.onreadystatechange = function() {
        if (this.readyState == 4 && this.status == 200) {
            var devices = [];
            try { devices = JSON.parse(this.responseText); } catch (e) { devices = []; }

            datalist.innerHTML = '';
            for (var i = 0; i < devices.length; i++) {
                var option = document.createElement('option');
                option.value = devices[i].value;
                option.textContent = devices[i].label;
                datalist.appendChild(option);
            }
        }
    };
    xhttp.open("GET", url, true);
    xhttp.send();
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

    // RTL-SDR USB device index or EEPROM serial number, from the tuner
    // page's "USB Device" field. Empty falls back to device 0 server-side.
    var usb_device_string = '';
    var usbDeviceElem = document.getElementById('usb_device_string');
    if (usbDeviceElem !== null) { usb_device_string = usbDeviceElem.value; }

    var tuningArray = {frequency:frequency, sample_rate: sample_rate, tuner_gain: tuner_gain, stereo_flag: stereo_flag, modulation: modulation, usb_device_string: usb_device_string};

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


function gqrxListenButtonClicked(form)
{
  var formArray = $(form).serializeArray();
  var jsonData = JSON.stringify(formArray);

  // request to HTTP server to start the Gqrx UDP-relay pipeline
  var getUrl = window.location;
  var baseUrl = getUrl .protocol + "//" + getUrl.host + "/";
  var listenButtonClickedUrl = baseUrl + "gqrxlistenbuttonclicked.html";

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


function recordingListenButtonClicked(form)
{
  var selected = form.querySelector('input[name="selected_file"]:checked');
  if (!selected)
  {
    alert("Select a recording first.");
    return;
  }

  var formArray = $(form).serializeArray();
  var jsonData = JSON.stringify(formArray);

  // request to HTTP server to start the PCMFilePlayer pipeline
  var getUrl = window.location;
  var baseUrl = getUrl .protocol + "//" + getUrl.host + "/";
  var listenButtonClickedUrl = baseUrl + "recordingslistenbuttonclicked.html";

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


// Formats the browser's own <audio> element can decode directly. Matches
// AntennaHeadHTTPServer.recordingsFileExtensions minus "caf" (Core Audio
// Format isn't supported by any browser's <audio> element — Listen works
// around that by having PCMFilePlayer decode server-side before it ever
// reaches the browser, but the fast-download route below serves the raw
// file, so the browser has to decode it itself).
var recordingsBrowserPlayableExtensions = ["aac", "mp3", "m4a", "wav"];


// "Download & Play": points the persistent <audio> element straight at the
// file via the fast-download route (recordings-download/<name>, Range-
// enabled — see recordingDownloadResponse() server-side) instead of routing
// it through the live PCMFilePlayer/HLS pipeline the way Listen does. That
// gives the browser's native seek bar something it can actually scrub
// (HLS's live playlist has no seekable timeline), at the cost of there being
// no live stream left to fall back to once the file finishes playing.
function recordingDownloadButtonClicked(form)
{
  var selected = form.querySelector('input[name="selected_file"]:checked');
  if (!selected)
  {
    alert("Select a recording first.");
    return;
  }

  var fileName = selected.value;
  var ext = fileName.split('.').pop().toLowerCase();
  if (recordingsBrowserPlayableExtensions.indexOf(ext) === -1)
  {
    alert("The \"" + fileName + "\" recording is a ." + ext + " file, which browsers can't play directly. Use Listen instead, or choose a .aac/.mp3/.m4a/.wav recording.");
    return;
  }

  var repeatCheckbox = form.querySelector('#recordings_repeat');
  var repeatFlag = !!(repeatCheckbox && repeatCheckbox.checked);

  var getUrl = window.location;
  var baseUrl = getUrl.protocol + "//" + getUrl.host + "/";
  var downloadUrl = baseUrl + "recordings-download/" + encodeURIComponent(fileName);

  window.top.nowPlayingTitle = window.document.getElementById("listen_title");

  // Tell the top frame's persistent <audio> element to switch into
  // fast-download mode. See handleAudioPlayerMessage()/startDownloadAudioPlayer()
  // in index.html for the receiving end of this message.
  window.top.postMessage("startdownloadaudio:" + (repeatFlag ? "1" : "0") + ":" + encodeURIComponent(downloadUrl), "*");

  //console.log("postMessage startdownloadaudio");
}


// Client-side filter/sort for the Recordings page table (js only — no round
// trip to the server while typing). Rows carry data-name (lowercased),
// data-date (epoch seconds) and data-size (bytes) attributes rendered by
// recordingsListHTML().
function filterRecordingsTable()
{
  var filterInput = document.getElementById("recordings_filter");
  if (!filterInput) { return; }
  var query = filterInput.value.trim().toLowerCase();
  var rows = document.querySelectorAll("#recordingsTableBody tr.recording-row");
  rows.forEach(function(row) {
    var name = row.getAttribute("data-name") || "";
    row.style.display = (query === "" || name.indexOf(query) !== -1) ? "" : "none";
  });
}


function sortRecordingsTable()
{
  var sortSelect = document.getElementById("recordings_sort");
  var tbody = document.getElementById("recordingsTableBody");
  if (!sortSelect || !tbody) { return; }
  var mode = sortSelect.value;
  var rows = Array.prototype.slice.call(tbody.querySelectorAll("tr.recording-row"));
  rows.sort(function(a, b) {
    if (mode === "date")
    {
      return parseFloat(b.getAttribute("data-date")) - parseFloat(a.getAttribute("data-date"));
    }
    if (mode === "size")
    {
      return (parseFloat(b.getAttribute("data-size")) || 0) - (parseFloat(a.getAttribute("data-size")) || 0);
    }
    var nameA = a.getAttribute("data-name") || "";
    var nameB = b.getAttribute("data-name") || "";
    return nameA.localeCompare(nameB);
  });
  rows.forEach(function(row) { tbody.appendChild(row); });
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

    gqrxUpdatePanel(statusObj.gqrx);

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
    var tuner_gain_display = statusObj.tuner_gain_display;
    var usb_device_string = statusObj.usb_device_string;
    var usb_device_display = statusObj.usb_device_display;
    var channels_display = statusObj.channels_display;
    
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
        if (channels_display)
        {
          statusHtml += "channels: ";
          statusHtml += channels_display;
          statusHtml += "<br>";
        }
        statusHtml += "sampling mode: ";
        statusHtml += sampling_mode;
        statusHtml += "<br>";
        statusHtml += "oversampling: ";
        statusHtml += oversampling;
        statusHtml += "<br>";
        statusHtml += "tuner gain: ";
        statusHtml += (tuner_gain_display != null && tuner_gain_display !== "") ? tuner_gain_display : tuner_gain;
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
        statusHtml += "device: ";
        statusHtml += (usb_device_display != null && usb_device_display !== "") ? usb_device_display : usb_device_string;
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


// Spatial-audio sliders (see spatialAudioControlsHTML() in
// AntennaHeadHTTPServer.swift, which renders these — this page has no
// <script> of its own since fragments are injected via innerHTML, so the
// sliders' oninput points here instead).
//
// Sends the *current* value of all three sliders on every input event,
// not just the one that moved — simpler than tracking which changed, and
// the server applies whichever of azimuth/elevation/distance parse, so a
// slider that isn't on the page (spatial audio just doesn't render it)
// is silently skipped rather than sent as some placeholder value.
function spatialAudioSliderChanged(id)
{
    var slider = document.getElementById(id);
    if (slider == null) { return; }

    var valueSpan = document.getElementById(id + "-value");
    if (valueSpan != null)
    {
        var value = parseFloat(slider.value);
        // Matches the server's own formatting (spatialAudioControlsHTML):
        // degrees with no decimal and a degree sign, distance to 2 places.
        valueSpan.innerText = (id === "spatial-distance") ? value.toFixed(2) : (value.toFixed(0) + "°");
    }

    var payload = {};
    var azimuthEl = document.getElementById("spatial-azimuth");
    var elevationEl = document.getElementById("spatial-elevation");
    var distanceEl = document.getElementById("spatial-distance");
    if (azimuthEl != null) { payload.azimuth = parseFloat(azimuthEl.value); }
    if (elevationEl != null) { payload.elevation = parseFloat(elevationEl.value); }
    if (distanceEl != null) { payload.distance = parseFloat(distanceEl.value); }

    var getUrl = window.location;
    var baseUrl = getUrl.protocol + "//" + getUrl.host + "/";
    var xhttp = new XMLHttpRequest();
    xhttp.open("POST", baseUrl + "api/spatial-audio/update", true);
    xhttp.send(JSON.stringify(payload));
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


// Settings page: Light / Dark / Auto colour scheme. Persists the choice
// (POST -> /applywebuitheme.html; cosmetic, no service restart) and applies
// it live. settings.html is injected into index.html's #content_frame, so
// document.documentElement here is index.html's own <html> element — the
// one that carries data-theme (see css/custom.css and the %%THEME%% token).
function applyWebUITheme(form)
{
    var select = document.getElementById("web_ui_theme_select");
    if (select === null) { return false; }
    var theme = select.options[select.selectedIndex].value;

    document.documentElement.setAttribute("data-theme", theme);

    var getUrl = window.location;
    var baseUrl = getUrl.protocol + "//" + getUrl.host + "/";

    var xhttp = new XMLHttpRequest();
    xhttp.open("POST", baseUrl + "applywebuitheme.html", true);
    xhttp.send(JSON.stringify({theme: theme}));

    return false;
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
        btn.title = "Click to start/stop audio recording";
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
        btn.title = "Click to start/stop audio recording";
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


// ---- ControlBooth Remote Control (controlbooth.html) --------------------
//
// Polls /api/v1/controlbooth/status — reflects ControlBoothClient
// .isControlBoothRunning, an NSRunningApplication check that goes false
// essentially the moment the process exits. ControlBooth also sends
// AntennaHead a 'CBQt' AppleEvent from applicationWillTerminate (see
// ControlBoothEventReceiver) so the quit is logged right away, but there's
// no push channel from server to browser here — so if this page is open
// when ControlBooth quits, it's this poll noticing isRunning no longer
// matches what was rendered that reloads the fragment (same call the
// Refresh button makes) to show "Not running". No-op until the fragment
// (and its data-running marker) is in the DOM, same as aacRecorderPoll.
function controlBoothPoll()
{
    var statusEl = document.getElementById("controlbooth_status");
    if (!statusEl) return;

    var xhttp = new XMLHttpRequest();
    xhttp.onreadystatechange = function() {
        if (this.readyState == 4 && this.status == 200) {
            try {
                var data = JSON.parse(this.responseText);
                var renderedRunning = (statusEl.getAttribute("data-running") == "true");
                if (!!data.isRunning !== renderedRunning)
                {
                    loadContent("controlbooth.html");
                }
            } catch (e) { /* ignore a malformed response */ }
        }
    };
    xhttp.open("GET", "/api/v1/controlbooth/status", true);
    xhttp.send();
}

var controlBoothPollIntervalID = setInterval(controlBoothPoll, 3000);


// ---- Live Captions (captions.html) -------------------------------------
//
// Polls /captions.json — served by AntennaHeadHTTPServer from
// SDRController's TranscriptionCaptionListener, which consumes the
// PCMTranscriber tap's newline-delimited JSON on UDP 6023. Runs globally
// like aacRecorderPoll(); it's a no-op until the captions fragment is in
// the DOM. Shape: {"enabled":bool, "live":str, "final":[str,...]}.
var captionsLastRenderedSeq = -1;
var captionsPollInFlight = false;

function captionsPoll()
{
    if (!document.getElementById("caption-live")) return;   // fragment not loaded
    if (captionsPollInFlight) return;                       // a slow server must not pile requests up

    var xhttp = new XMLHttpRequest();
    xhttp.onreadystatechange = function() {
        if (this.readyState == 4) {
            captionsPollInFlight = false;
            if (this.status == 200) {
                try {
                    updateCaptionsDisplay(JSON.parse(this.responseText));
                } catch (e) { /* ignore a malformed frame */ }
            }
        }
    };
    xhttp.timeout = 4000;
    xhttp.ontimeout = xhttp.onerror = function() { captionsPollInFlight = false; };
    captionsPollInFlight = true;
    xhttp.open("GET", "/captions.json", true);
    xhttp.send();
}

function captionsEscapeHTML(s)
{
    return String(s)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
}

function updateCaptionsDisplay(data)
{
    var enabled = !!(data && data.enabled);

    var notice = document.getElementById("caption-disabled-notice");
    if (notice) notice.style.display = enabled ? "none" : "";

    var transcript = document.getElementById("caption-transcript");
    if (transcript)
    {
        var finals = (data && data.final) || [];
        // Key the rebuild on the server's monotonic `seq`, not finals.length:
        // once the server-side history ring hits its cap the length stops
        // changing while new segments keep rolling in, and a length check would
        // freeze the transcript. Fall back to the length if an older server
        // omits `seq`. Also rebuild when the fragment was just re-opened and
        // left the node empty. Skipping unchanged polls keeps scrolling steady.
        var seq = (data && typeof data.seq === "number") ? data.seq : finals.length;
        if (seq !== captionsLastRenderedSeq ||
            (transcript.innerHTML === "" && finals.length > 0))
        {
            captionsLastRenderedSeq = seq;
            var html = "";
            for (var i = 0; i < finals.length; i++)
            {
                html += "<p>" + captionsEscapeHTML(finals[i]) + "</p>";
            }
            transcript.innerHTML = html;
            transcript.scrollTop = transcript.scrollHeight;   // keep newest in view
        }
    }

    var live = document.getElementById("caption-live");
    if (live)
    {
        var text = (data && data.live) || "";
        if (live.textContent !== text) live.textContent = text;
    }
}

var captionsPollIntervalID = setInterval(captionsPoll, 750);


// ---- Text to Speech (Audio Devices page) --------------------------------
//
// "Select Text Folder…" asks the server to run a native folder chooser on the
// Mac running AntennaHead; the choice is saved as a persistent setting
// (security-scoped bookmark). Listen just tells the server the order and the
// repeat flag — the server resolves the saved folder, reads its .txt files,
// and feeds them to the PCMSpeechSynth pipeline stage.

function textToSpeechChooseFolderButtonClicked()
{
  var status = document.getElementById("tts_folder_status");
  if (status) { status.textContent = "Choose a folder in the panel on the AntennaHead Mac…"; }

  var getUrl = window.location;
  var baseUrl = getUrl.protocol + "//" + getUrl.host + "/";

  var xhttp = new XMLHttpRequest();
  xhttp.onreadystatechange = function() {
      if (this.readyState == 4)
      {
        if (this.status == 200)
        {
          var path = (this.responseText || "").trim();
          if (status) { status.textContent = path ? path : "No folder selected."; }
        }
        else if (status)
        {
          status.textContent = "Could not open the folder chooser.";
        }
      }
    };
  xhttp.open("POST", baseUrl + "texttospeechchoosefolder.html", true);
  xhttp.send();
}

function textToSpeechListenButtonClicked(form)
{
  var sequenceSelect = form.querySelector("#tts_sequence");
  var repeatCheckbox = form.querySelector("#tts_repeat");
  var payload = {
    sequence: sequenceSelect ? sequenceSelect.value : "chronological",
    repeat: (repeatCheckbox && repeatCheckbox.checked) ? "1" : "0"
  };

  var getUrl = window.location;
  var baseUrl = getUrl.protocol + "//" + getUrl.host + "/";
  var listenButtonClickedUrl = baseUrl + "texttospeechlistenbuttonclicked.html";

  var xhttp = new XMLHttpRequest();
  xhttp.onreadystatechange = function() {
      if (this.readyState == 4 && this.status == 200) {
        // response received ok
        window.top.nowPlayingTitle = window.document.getElementById("listen_title");
      }
    };
  xhttp.open("POST", listenButtonClickedUrl, true);
  xhttp.setRequestHeader("Content-Type", "application/json");
  xhttp.send(JSON.stringify(payload));

  // handle the audio tag with the new source
  window.top.postMessage("startaudio", "*");
}


/* ==================================================================
   Tap / click acknowledgement.

   Pressing a button here often does nothing visible for a second or
   two — until the audio player spins up or a new program is
   announced — because index.html's loadContent() swaps
   #content_frame's innerHTML on the same tick, destroying the
   pressed control before a CSS :active highlight can paint.

   initTapFeedback() installs ONE delegated pointerdown listener on
   document (capture phase, so it runs before the element's own
   onclick and before any content swap). On a press over a button-ish
   control it:
     - adds .ah-tap-flash to that control (see css/custom.css) — only
       seen when the control outlives the tap (toggles, tuner digits,
       settings forms), which is fine;
     - drops a .ah-tap-ripple <span> on <body> at the pointer point.
       <body> is never re-rendered, so the ripple always shows; it is
       pointer-events:none and self-removes on animationend.

   Purely visual (no sound / no haptics, per request). Honours
   prefers-reduced-motion via CSS, and a Settings toggle stored in
   localStorage["ahTapFeedback"] (=== "0" disables; default on).
   Never calls preventDefault/stopPropagation, so it cannot alter
   how any existing handler behaves.
   ================================================================== */

// Controls that should acknowledge a press. [onclick] catches the
// inline-handler <a>/<input>/<button> elements the fragments use, plus
// any future ones, without having to enumerate them here.
var AH_TAP_SELECTOR = '.button, button, input[type="submit"], input[type="button"], input[type="reset"], .tuner-digit, [onclick]';

function ahTapFeedbackEnabled()
{
    try { return window.localStorage.getItem("ahTapFeedback") !== "0"; }
    catch (e) { return true; }   // private mode / storage disabled → default on
}

function ahSpawnTapRipple(x, y)
{
    var host = document.body || document.documentElement;
    if (!host) { return; }

    var ripple = document.createElement("span");
    ripple.className = "ah-tap-ripple";
    ripple.style.left = x + "px";
    ripple.style.top = y + "px";
    host.appendChild(ripple);

    var remove = function ()
    {
        if (ripple && ripple.parentNode) { ripple.parentNode.removeChild(ripple); }
    };
    ripple.addEventListener("animationend", remove);
    setTimeout(remove, 700);   // belt-and-braces if animationend is missed
}

function ahFlashTapControl(el)
{
    if (!el || !el.classList) { return; }
    el.classList.remove("ah-tap-flash");
    void el.offsetWidth;            // reflow so the animation restarts on a fast repeat tap
    el.classList.add("ah-tap-flash");
    setTimeout(function () {
        if (el && el.classList) { el.classList.remove("ah-tap-flash"); }
    }, 400);
}

function ahHandleTapFeedback(targetEl, x, y)
{
    if (!ahTapFeedbackEnabled()) { return; }

    var control = (targetEl && targetEl.closest) ? targetEl.closest(AH_TAP_SELECTOR) : null;
    if (!control) { return; }

    // Coordinates come from the pointer/touch/mouse event; fall back to
    // the control's centre for keyboard-activated presses.
    if (typeof x !== "number" || isNaN(x) || (x === 0 && y === 0))
    {
        var rect = control.getBoundingClientRect();
        x = rect.left + rect.width / 2;
        y = rect.top + rect.height / 2;
    }

    ahSpawnTapRipple(x, y);
    ahFlashTapControl(control);
}

function initTapFeedback()
{
    if (window.ahTapFeedbackInstalled) { return; }
    window.ahTapFeedbackInstalled = true;

    if ("PointerEvent" in window)
    {
        document.addEventListener("pointerdown", function (event) {
            ahHandleTapFeedback(event.target, event.clientX, event.clientY);
        }, true);
    }
    else
    {
        document.addEventListener("touchstart", function (event) {
            var t = event.changedTouches && event.changedTouches[0];
            ahHandleTapFeedback(event.target, t ? t.clientX : 0, t ? t.clientY : 0);
        }, true);
        document.addEventListener("mousedown", function (event) {
            ahHandleTapFeedback(event.target, event.clientX, event.clientY);
        }, true);
    }
}

// Called from index.html's bodyElementLoaded() once the shell is up.
if (document.readyState === "loading")
{
    document.addEventListener("DOMContentLoaded", initTapFeedback);
}
else
{
    initTapFeedback();
}


/* ---- Settings › Feedback toggle -------------------------------------
   settings.html carries <input type="checkbox" id="tap_feedback_toggle">.
   Fragments are injected via innerHTML so their inline <script> never
   runs; loadContent() calls initFeedbackSettings() after each injection
   (mirrors initTunerDigitKeyboard()), and it no-ops when the checkbox
   isn't on the current fragment. The checkbox's onchange calls
   setTapFeedbackEnabled(). */

function setTapFeedbackEnabled(enabled)
{
    try { window.localStorage.setItem("ahTapFeedback", enabled ? "1" : "0"); }
    catch (e) { /* storage unavailable — setting just won't persist */ }
}

function initFeedbackSettings()
{
    var toggle = document.getElementById("tap_feedback_toggle");
    if (!toggle) { return; }
    toggle.checked = ahTapFeedbackEnabled();
}


// ─────────────────────────────────────────────────────────────────────────────
// "Listen to Gqrx" remote-control panel.
//
// Rendered hidden by gqrxControlPanelHTML() in AntennaHeadHTTPServer.swift.
// updateStatusDisplay() calls gqrxUpdatePanel() on every poll with the `gqrx`
// object from nowplayingstatus.html; writes go to the /gqrx* endpoints in the
// jQuery serializeArray() shape the server's formFields() parser expects.

var gqrxModesInit = false;
var gqrxBookmarksData = null;
var gqrxTouched = {};          // control id -> last user-interaction timestamp
var gqrxDebounceTimers = {};

function gqrxPost(path, obj)
{
    var arr = [];
    for (var k in obj) { if (obj.hasOwnProperty(k)) { arr.push({ name: k, value: String(obj[k]) }); } }
    var base = window.location.protocol + "//" + window.location.host + "/";
    var x = new XMLHttpRequest();
    x.open("POST", base + path, true);
    x.send(JSON.stringify(arr));
}

function gqrxDebounce(key, fn, ms)
{
    if (gqrxDebounceTimers[key]) { clearTimeout(gqrxDebounceTimers[key]); }
    gqrxDebounceTimers[key] = setTimeout(function () { gqrxDebounceTimers[key] = null; fn(); }, ms);
}

function gqrxMark(id) { gqrxTouched[id] = Date.now(); }
function gqrxFresh(id) { return (Date.now() - (gqrxTouched[id] || 0)) < 1500; }

function gqrxSetVal(id, text)
{
    var el = document.getElementById(id);
    if (el != null) { el.innerText = text; }
}

// ── live refresh from the poll ───────────────────────────────────────────────

function gqrxUpdatePanel(g)
{
    var panel = document.getElementById("gqrxPanel");
    if (panel == null) { return; }                 // not on the Gqrx page
    if (g == null) { panel.hidden = true; return; }
    panel.hidden = false;

    var status = document.getElementById("gqrxStatus");
    if (status != null)
    {
        status.innerText = g.available
            ? "Connected to Gqrx on port 7356"
            : "Gqrx remote control not reachable — enable Tools ▸ Remote control in Gqrx";
        status.className = "gqrx-status" + (g.available ? " ok" : " bad");
    }

    // Mode dropdown — populate once from the modes Gqrx reported.
    var modeSel = document.getElementById("gqrxMode");
    if (modeSel != null && !gqrxModesInit && g.modes && g.modes.length)
    {
        modeSel.innerHTML = "";
        for (var i = 0; i < g.modes.length; i++)
        {
            var o = document.createElement("option");
            o.value = g.modes[i]; o.text = g.modes[i];
            modeSel.appendChild(o);
        }
        gqrxModesInit = true;
    }
    if (modeSel != null && !gqrxFresh("gqrxMode") && g.mode) { modeSel.value = g.mode; }

    if (!gqrxFresh("gqrxFreq"))
    {
        var f = document.getElementById("gqrxFreq");
        if (f != null && document.activeElement !== f && g.frequency)
        {
            f.value = (g.frequency / 1e6).toFixed(3);
        }
    }

    if (!gqrxFresh("gqrxWidth"))
    {
        var w = document.getElementById("gqrxWidth");
        if (w != null && g.passband) { w.value = g.passband; }
        gqrxSetVal("gqrxWidthVal", (g.passband ? (g.passband / 1000).toFixed(1) + " kHz" : ""));
    }

    var shapeRow = document.getElementById("gqrxShapeRow");
    if (shapeRow != null)
    {
        shapeRow.hidden = !g.has_filter_shape;
        var sh = document.getElementById("gqrxShape");
        if (sh != null && g.has_filter_shape && !gqrxFresh("gqrxShape"))
        {
            sh.value = String(g.filter_shape);
        }
    }

    var rfRow = document.getElementById("gqrxRFRow");
    if (rfRow != null)
    {
        var hasRF = g.rf_gain_name && g.rf_gain_name.length > 0;
        rfRow.hidden = !hasRF;
        if (hasRF)
        {
            gqrxSetVal("gqrxRFName", g.rf_gain_name);
            if (!gqrxFresh("gqrxRF"))
            {
                var rf = document.getElementById("gqrxRF");
                if (rf != null) { rf.value = g.rf_gain; }
                gqrxSetVal("gqrxRFVal", (g.rf_gain != null ? Number(g.rf_gain).toFixed(1) : ""));
            }
        }
    }

    if (!gqrxFresh("gqrxAF"))
    {
        var af = document.getElementById("gqrxAF");
        if (af != null && g.af_gain != null) { af.value = Math.round(g.af_gain); }
        gqrxSetVal("gqrxAFVal", (g.af_gain != null ? Number(g.af_gain).toFixed(0) : "–"));
    }
    if (!gqrxFresh("gqrxSql"))
    {
        var sq = document.getElementById("gqrxSql");
        if (sq != null && g.squelch != null) { sq.value = Math.round(g.squelch); }
        gqrxSetVal("gqrxSqlVal", (g.squelch != null ? Number(g.squelch).toFixed(0) : "–"));
    }

    gqrxSetVal("gqrxSig", (g.signal != null ? Number(g.signal).toFixed(1) : "–"));
    var bar = document.getElementById("gqrxSigBar");
    if (bar != null && g.signal != null)
    {
        var pct = Math.max(0, Math.min(100, (Number(g.signal) + 120) / 120 * 100));
        bar.style.width = pct.toFixed(0) + "%";
    }

    if (!gqrxFresh("gqrxMute"))
    {
        var mu = document.getElementById("gqrxMute");
        if (mu != null) { mu.checked = !!g.muted; }
    }

    var bmRow = document.getElementById("gqrxBookmarksRow");
    if (bmRow != null)
    {
        var have = g.bookmarks && g.bookmarks.length > 0;
        bmRow.hidden = !have;
        if (have && gqrxBookmarksData === null)
        {
            gqrxBookmarksData = g.bookmarks;
            gqrxRenderBookmarks();
        }
    }
}

function gqrxRenderBookmarks()
{
    var box = document.getElementById("gqrxBookmarks");
    if (box == null || gqrxBookmarksData == null) { return; }
    var filterEl = document.getElementById("gqrxBmFilter");
    var q = filterEl ? filterEl.value.trim().toLowerCase() : "";

    box.innerHTML = "";
    for (var i = 0; i < gqrxBookmarksData.length; i++)
    {
        var b = gqrxBookmarksData[i];
        var hay = (b.name + " " + (b.tags || []).join(" ") + " " + b.modulation).toLowerCase();
        if (q && hay.indexOf(q) === -1) { continue; }

        var row = document.createElement("div");
        row.className = "gqrx-bm";
        var label = document.createElement("span");
        label.className = "gqrx-bm-name";
        label.innerText = (b.frequency / 1e6).toFixed(4) + "  " + b.name;
        var btn = document.createElement("input");
        btn.type = "button";
        btn.className = "button gqrx-bm-btn";
        btn.value = "Tune";
        (function (hz) { btn.onclick = function () { gqrxPost("gqrxbookmark.html", { freq: hz }); }; })(b.frequency);
        row.appendChild(label);
        row.appendChild(btn);
        box.appendChild(row);
    }
}

// ── user actions ────────────────────────────────────────────────────────────

function gqrxSetFreq()
{
    var f = document.getElementById("gqrxFreq");
    if (f == null || f.value === "") { return; }
    var hz = Math.round(parseFloat(f.value) * 1e6);
    if (!isFinite(hz)) { return; }
    gqrxMark("gqrxFreq");
    gqrxPost("gqrxsetfrequency.html", { freq: hz });
}

function gqrxWidthInput()
{
    gqrxMark("gqrxWidth");
    var w = document.getElementById("gqrxWidth");
    if (w != null) { gqrxSetVal("gqrxWidthVal", (parseInt(w.value, 10) / 1000).toFixed(1) + " kHz"); }
}

function gqrxSendMode()
{
    gqrxMark("gqrxMode"); gqrxMark("gqrxWidth");
    var m = document.getElementById("gqrxMode");
    var w = document.getElementById("gqrxWidth");
    if (m == null || m.value === "") { return; }
    gqrxPost("gqrxsetmode.html", { mode: m.value, passband: (w ? parseInt(w.value, 10) : 0) });
}

function gqrxSendShape()
{
    gqrxMark("gqrxShape");
    var s = document.getElementById("gqrxShape");
    if (s != null) { gqrxPost("gqrxsetshape.html", { shape: s.value }); }
}

function gqrxRFInput()
{
    gqrxMark("gqrxRF");
    var rf = document.getElementById("gqrxRF");
    if (rf != null) { gqrxSetVal("gqrxRFVal", parseFloat(rf.value).toFixed(1)); }
    gqrxDebounce("rf", gqrxSendRF, 120);
}
function gqrxSendRF()
{
    gqrxMark("gqrxRF");
    var rf = document.getElementById("gqrxRF");
    var name = document.getElementById("gqrxRFName");
    if (rf != null && name != null) { gqrxPost("gqrxsetlevel.html", { name: name.innerText + "_GAIN", value: rf.value }); }
}

function gqrxAFInput()
{
    gqrxMark("gqrxAF");
    var af = document.getElementById("gqrxAF");
    if (af != null) { gqrxSetVal("gqrxAFVal", parseFloat(af.value).toFixed(0)); }
    gqrxDebounce("af", gqrxSendAF, 120);
}
function gqrxSendAF()
{
    gqrxMark("gqrxAF");
    var af = document.getElementById("gqrxAF");
    if (af != null) { gqrxPost("gqrxsetlevel.html", { name: "AF", value: af.value }); }
}

function gqrxSqlInput()
{
    gqrxMark("gqrxSql");
    var sq = document.getElementById("gqrxSql");
    if (sq != null) { gqrxSetVal("gqrxSqlVal", parseFloat(sq.value).toFixed(0)); }
    gqrxDebounce("sql", gqrxSendSql, 120);
}
function gqrxSendSql()
{
    gqrxMark("gqrxSql");
    var sq = document.getElementById("gqrxSql");
    if (sq != null) { gqrxPost("gqrxsetlevel.html", { name: "SQL", value: sq.value }); }
}

function gqrxToggleMute()
{
    gqrxMark("gqrxMute");
    var mu = document.getElementById("gqrxMute");
    if (mu != null) { gqrxPost("gqrxmute.html", { on: mu.checked ? 1 : 0 }); }
}
