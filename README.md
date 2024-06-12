# Shared Storage API Explainer

Authors: Alex Turner, Camillia Smith Barnes, Josh Karlin, Yao Xiao


## Introduction 

In order to prevent cross-site user tracking, browsers are [partitioning](https://blog.chromium.org/2020/01/building-more-private-web-path-towards.html) all forms of storage (cookies, localStorage, caches, etc) by top-frame site. But, there are many legitimate use cases currently relying on unpartitioned storage that will vanish without the help of new web APIs. We’ve seen a number of APIs proposed to fill in these gaps (e.g., [Conversion Measurement API](https://github.com/WICG/conversion-measurement-api), [Private Click Measurement](https://github.com/privacycg/private-click-measurement), [Storage Access](https://developer.mozilla.org/en-US/docs/Web/API/Storage_Access_API), [Private State Tokens](https://github.com/WICG/trust-token-api), [TURTLEDOVE](https://github.com/WICG/turtledove), [FLoC](https://github.com/WICG/floc)) and some remain (including cross-origin A/B experiments and user measurement). We propose a general-purpose, low-level API that can serve a number of these use cases.

The idea is to provide a storage API (named Shared Storage) that is intentionally not partitioned by top-frame site (though still partitioned by context origin of course!). To limit cross-site reidentification of users, data in Shared Storage may only be read in a restricted environment that has carefully constructed output gates. Over time, we hope to design and add additional gates.

### Specification

See the [draft specification](https://wicg.github.io/shared-storage/).

### Demonstration 

You can [try it out](https://shared-storage-demo.web.app/) using Chrome 104+ (currently in canary and dev channels as of June 7th 2022).


### Simple example: Consistent A/B experiments across sites

A third-party, `a.example`, wants to randomly assign users to different groups (e.g. experiment vs control) in a way that is consistent cross-site.

To do so, `a.example` writes a seed to its shared storage (which is not added if already present). `a.example` then registers and runs an operation in the shared storage [worklet](https://developer.mozilla.org/en-US/docs/Web/API/Worklet) that assigns the user to a group based on the seed and the experiment name and chooses the appropriate ad for that group.

In an `a.example` document: 


```js
function generateSeed() { … }
await window.sharedStorage.worklet.addModule('experiment.js');

// Only write a cross-site seed to a.example's storage if there isn't one yet.
window.sharedStorage.set('seed', generateSeed(), { ignoreIfPresent: true });

// Fenced frame config contains an opaque form of the URL (urn:uuid) that is created by 
// privileged code to avoid leaking the chosen input URL back to the document.

const fencedFrameConfig = await window.sharedStorage.selectURL(
  'select-url-for-experiment',
  [
    {url: "blob:https://a.example/123…", reportingMetadata: {"click": "https://report.example/1..."}},
    {url: "blob:https://b.example/abc…", reportingMetadata: {"click": "https://report.example/a..."}},
    {url: "blob:https://c.example/789…"}
  ],
  { 
    data: { name: 'experimentA' }, 
    resolveToConfig: true
  }
);

document.getElementById('my-fenced-frame').config = fencedFrameConfig;
```


Worklet script (i.e. `experiment.js`):


```js
class SelectURLOperation {
  hash(experimentName, seed) { … }

  async run(data, urls) {
    const seed = await this.sharedStorage.get('seed');
    return hash(data.name, seed) % urls.length;
  }
}
register('select-url-for-experiment', SelectURLOperation);
```


While the worklet script outputs the chosen index for `urls`, note that the browser process converts the index into a non-deterministic [opaque URL](https://github.com/WICG/fenced-frame/blob/master/explainer/use_cases.md#opaque-ads), and is returned via [fenced frame config](https://github.com/WICG/fenced-frame/blob/master/explainer/fenced_frame_config.md), which can only be read or rendered in a [fenced frame](https://github.com/WICG/fenced-frame). Because of this, the `a.example` iframe cannot itself work out which ad was chosen. Yet, it is still able to customize the ad it rendered based on this protected information.


## Goals

This API intends to support a wide array of use cases, replacing many of the existing uses of third-party cookies. These include recording (aggregate) statistics — e.g. demographics, reach, interest, anti-abuse, and conversion measurement — A/B experimentation, different documents depending on if the user is logged in, and interest-based selection. Enabling these use cases will help to support a thriving open web. Additionally, by remaining generic and flexible, this API aims to foster continued growth, experimentation, and rapid iteration in the web ecosystem and to avert ossification and unnecessary rigidity.

However, this API also seeks to avoid the privacy loss and abuses that third-party cookies have enabled. In particular, it aims to limit cross-site reidentification of a user. Wide adoption of this more privacy-preserving API by developers will make the web much more private by default in comparison to the third-party cookies it helps to replace.


## Related work

There have been multiple privacy proposals ([SPURFOWL](https://github.com/AdRoll/privacy/blob/main/SPURFOWL.md), [SWAN](https://github.com/1plusX/swan), [Aggregated Reporting](https://github.com/csharrison/aggregate-reporting-api)) that have a notion of write-only storage with limited output. This API is similar to those, but tries to be more general to support a greater number of output gates and use cases. We’d also like to acknowledge the [KV Storage](https://github.com/WICG/kv-storage) explainer, to which we turned for API-shape inspiration.

## Fenced frame enforcement

The usage of fenced frames with the URL Selection operation will not be required until at least 2026. We will provide significant advanced notice before the fenced frame usage is required. Until 2026, you are free to use an iframe with URL Selection instead of a fenced frame. 

To use an iframe, omit passing in the `resolveToConfig` flag or set it to `false`, and set the returned opaque URN to the `src` attribute of the iframe. 

```js
const opaqueURN = await window.sharedStorage.selectURL(
  'select-url-for-experiment',
  { 
    data: { ... } 
  }
);

document.getElementById('my-iframe').src = opaqueURN;
```

## Proposed API surface


### Outside the worklet
The setter methods (`set`, `append`, `delete`, and `clear`) should be made generally available across most any context. That includes top-level documents, iframes, shared storage worklets,  Protected Audience worklets, service workers, dedicated workers, etc.

The shared storage worklet invocation methods (`addModule`, `run`, and `selectURL`) are available within document contexts.


*   `window.sharedStorage.set(key, value, options)`
    *   Sets `key`’s entry to `value`.
    *   `key` and `value` are both strings.
    *   Options include:
        *   `ignoreIfPresent` (defaults to false): if true, a `key`’s entry is not updated if the `key` already exists. The embedder is not notified which occurred.
*   `window.sharedStorage.append(key, value)`
    *   Appends `value` to the entry for `key`. Equivalent to `set` if the `key` is not present.
*   `window.sharedStorage.delete(key)`
    *   Deletes the entry at the given `key`.
*   `window.sharedStorage.clear()`
    *   Deletes all entries.
*   `window.sharedStorage.worklet.addModule(url, options)`
    *   Loads and adds the module to the worklet (i.e. for registering operations). The handling should follow the [worklet standard](https://html.spec.whatwg.org/multipage/worklets.html#dom-worklet-addmodule), unless clarified otherwise below.
    *   This method can only be invoked once per worklet. This is because after the initial script loading, shared storage data (for the invoking origin) will be made accessible inside the worklet environment, which can be leaked via subsequent `addModule()` (e.g. via timing).
    *   `url`'s origin need not match that of the context that invoked `addModule(url)`. 
        *   If `url` is cross-origin to the invoking context, the worklet will use the invoking context's origin as its partition origin for accessing shared storage data and for budget checking and withdrawing.
        *   Also, for a cross-origin`url`, the CORS protocol applies. 
    *   Redirects are not allowed.
*   `window.sharedStorage.worklet.run(name, options)`,  \
`window.sharedStorage.worklet.selectURL(name, urls, options)`, …
    *   Runs the operation previously registered by `register()` with matching `name`. Does nothing if there’s no matching operation.
    *   Each operation returns a promise that resolves when the operation is queued:
        *   `run()` returns a promise that resolves into `undefined`.
        *   `selectURL()` returns a promise that resolves into a [fenced frame config](https://github.com/WICG/fenced-frame/blob/master/explainer/fenced_frame_config.md) for fenced frames, and an opaque URN for iframes for the URL selected from `urls`.
            *   `urls` is a list of dictionaries, each containing a candidate URL `url` and optional reporting metadata (a dictionary, with the key being the event type and the value being the reporting URL; identical to Protected Audience's [registerAdBeacon()](https://github.com/WICG/turtledove/blob/main/Fenced_Frames_Ads_Reporting.md#registeradbeacon) parameter), with a max length of 8.
                *    The `url` of the first dictionary in the list is the `default URL`. This is selected if there is a script error, or if there is not enough budget remaining.
                *    The reporting metadata will be used in the short-term to allow event-level reporting via `window.fence.reportEvent()` as described in the [Protected Audience explainer](https://github.com/WICG/turtledove/blob/main/Fenced_Frames_Ads_Reporting.md).
            *    There will be a per-[site](https://html.spec.whatwg.org/multipage/browsers.html#site) (the site of the Shared Storage worklet) budget for `selectURL`. This is to limit the rate of leakage of cross-site data learned from the selectURL to the destination pages that the resulting Fenced Frames navigate to. Each time a Fenced Frame navigates the top frame, for each `selectURL()` involved in the creation of the Fenced Frame, log(|`urls`|) bits will be deducted from the corresponding [site](https://html.spec.whatwg.org/multipage/browsers.html#site)’s budget. At any point in time, the current budget remaining will be calculated as `max_budget - sum(deductions_from_last_24hr)`
            *    The promise resolves to a fenced frame config only when `resolveToConfig` property is set to `true`. If the property is set to `false` or not set, the promise resolves to an opaque URN that can be rendered by an iframe.
    *   Options can include:
        *   `data`, an arbitrary serializable object passed to the worklet. 
        *   `keepAlive` (defaults to false), a boolean denoting whether the worklet should be retained after it completes work for this call.
            *   If `keepAlive` is false or not specified, the worklet will shutdown as soon as the operation finishes and subsequent calls to it will fail.
            *   To keep the worklet alive throughout multiple calls to `run()` and/or `selectURL()`, each of those calls must include `keepAlive: true` in the `options` dictionary.
*   `window.sharedStorage.run(name, options)`,  \
`window.sharedStorage.selectURL(name, urls, options)`, …
    *   The behavior is identical to `window.sharedStorage.worklet.run(name, options)` and `window.sharedStorage.worklet.selectURL(name, urls, options)`.
*   `window.sharedStorage.createWorklet(url, options)`
    *   Creates a new worklet, and loads and adds the module to the worklet (similar to the handling for `window.sharedStorage.worklet.addModule(url, options)`).
    *   By default, the worklet uses the invoking context's origin as its partition origin for accessing shared storage data and for budget checking and withdrawing.
        *   To instead use the worklet script origin (i.e. `url`'s origin) as the partition origin for accessing shared storage, pass the `dataOrigin` option with "script-origin" as its value in the `options` dictionary.
        *   Currently, the `dataOrigin` option, if used, is restricted to having either "script-origin" or "context-origin" as its value. "script-origin" designates the worklet script origin as the data partition origin; "context-origin" designates the invoking context origin as the data partition origin.
    *   The object that the returned Promise resolves to has the same type with the implicitly constructed `window.sharedStorage.worklet`. However, for a worklet created via `window.sharedStorage.createWorklet(url, options)`, only `selectURL()` and `run()` are available, whereas calling `addModule()` will throw an error. This is to prevent leaking shared storage data via `addModule()`, similar to the reason why `addModule()` can only be invoked once on the implicitly constructed `window.sharedStorage.worklet`.
    *   Redirects are not allowed.
    *   When the module script's URL's origin is cross-origin with the worklet's creator window's origin and the `dataOrigin` option is different from the context origin, a `Shared-Storage-Cross-Origin-Worklet-Allowed: ?1` response header is required.
    *   The script server must carefully consider the security risks of allowing worklet creation by other origins (via `Shared-Storage-Cross-Origin-Worklet-Allowed: ?1` and CORS), because this will also allow the worklet creator to run subsequent operations, and a malicious actor could poison and use up the worklet origin's budget.



### In the worklet, during `sharedStorage.worklet.addModule(url, options)` or `sharedStorage.createWorklet(url, options)`



*   `register(name, operation)`
    *   Registers a shared storage worklet operation with the provided `name`.
    *   `operation` should be a class with an async `run()` method.
        *   For the operation to work with `sharedStorage.run()`, `run()` should take `data` as an argument and return nothing. Any return value is [ignored](#default).
        *   For the operation to work with `sharedStorage.selectURL()`, `run()` should take `data` and `urls` as arguments and return the index of the selected URL. Any invalid return value is replaced with a [default return value](#default).


### In the worklet, during an operation



*   `sharedStorage.get(key)`
    *   Returns a promise that resolves into the `key`‘s entry or an empty string if the `key` is not present.
*   `sharedStorage.length()`
    *   Returns a promise that resolves into the number of keys.
*   `sharedStorage.keys()` and `sharedStorage.entries()`
    *   Returns an async iterator for all the stored keys or [key, value] pairs, sorted in the underlying key order.
*   `sharedStorage.set(key, value, options)`, `sharedStorage.append(key, value)`, `sharedStorage.delete(key)`, and `sharedStorage.clear()`
    *   Same as outside the worklet, except that the promise returned only resolves into `undefined` when the operation has completed.
*   `sharedStorage.remainingBudget()`
    *   Returns a number indicating the remaining available privacy budget for `sharedStorage.selectURL()`, in bits.   
*  `sharedStorage.context`
    *   From inside a worklet created inside a [fenced frame](https://github.com/wicg/fenced-frame/), returns a string of contextual information, if any, that the embedder had written to the [fenced frame](https://github.com/wicg/fenced-frame/)'s [FencedFrameConfig](https://github.com/WICG/fenced-frame/blob/master/explainer/fenced_frame_config.md) before the [fenced frame](https://github.com/wicg/fenced-frame/)'s navigation.
    *   If no contextual information string had been written for the given frame, returns undefined.
*   Functions exposed by the [Private Aggregation API](https://github.com/alexmturner/private-aggregation-api), e.g. `privateAggregation.contributeToHistogram()`.
    *   These functions construct and then send an aggregatable report for the private, secure [aggregation service](https://github.com/WICG/conversion-measurement-api/blob/main/AGGREGATION_SERVICE_TEE.md).
    *   The report contents (e.g. key, value) are encrypted and sent after a delay. The report can only be read by the service and processed into aggregate statistics.
    *   After a Shared Storage operation has been running for 5 seconds, Private Aggregation contributions are timed out. Any future contributions are ignored and contributions already made are sent in a report as if the Shared Storage operation had completed. 
*   Unrestricted access to identifying operations that would normally use up part of a page’s [privacy budget](http://github.com/bslassey/privacy-budget), e.g. `navigator.userAgentData.getHighEntropyValues()`


### From response headers

*  `set()`, `append()`, `delete()`, and `clear()` operations can be triggered via the HTTP response header `Shared-Storage-Write`.
*  This may provide a large performance improvement over creating a cross-origin iframe and writing from there, if a network request is otherwise required.
*   `Shared-Storage-Write` is a [List Structured Header](https://www.rfc-editor.org/rfc/rfc8941.html#name-lists).
    *   Each member of the [List](https://www.rfc-editor.org/rfc/rfc8941.html#name-lists) is a [String Item](https://www.rfc-editor.org/rfc/rfc8941.html#name-strings) or [Byte Sequence](https://www.rfc-editor.org/rfc/rfc8941.html#name-byte-sequences) denoting the operation to be performed, with any arguments for the operation as associated  [Parameters](https://www.rfc-editor.org/rfc/rfc8941.html#name-parameters).
    *   The order of [Items](https://www.rfc-editor.org/rfc/rfc8941.html#name-items) in the [List](https://www.rfc-editor.org/rfc/rfc8941.html#name-lists) is the order in which the operations will be performed.
    *   Operations correspond to [Items](https://www.rfc-editor.org/rfc/rfc8941.html#name-items) as follows:
        *   `set(<key>, <value>, {ignoreIfPresent: true})` &larr;&rarr; `set;key=<key>;value=<value>;ignore_if_present`
        *   `set(<key>, <value>, {ignoreIfPresent: false})` &larr;&rarr; `set;key=<key>;value=<value>;ignore_if_present=?0`
        *   `set(<key>, <value>)` &larr;&rarr; `set;key=<key>;value=<value>`
        *   `append(<key>, <value>)` &larr;&rarr; `append;key=<key>;value=<value>`
        *   `delete(<key>)` &larr;&rarr; `delete;key=<key>`
        *   `clear()` &larr;&rarr; `clear`
    *  `<key>` and `<value>` [Parameters](https://www.rfc-editor.org/rfc/rfc8941.html#name-parameters) are of type [String](https://www.rfc-editor.org/rfc/rfc8941.html#name-strings) or [Byte Sequence](https://www.rfc-editor.org/rfc/rfc8941.html#name-byte-sequences). 
        *   Note that [Strings](https://www.rfc-editor.org/rfc/rfc8941.html#name-strings) are defined as zero or more [printable ASCII characters](https://www.rfc-editor.org/rfc/rfc20.html), and this excludes tabs, newlines, carriage returns, and so forth.
        *   To pass a key and/or value that contains non-ASCII and/or non-printable [UTF-8](https://www.rfc-editor.org/rfc/rfc3629.html) characters, specify it as a [Byte Sequence](https://www.rfc-editor.org/rfc/rfc8941.html#name-byte-sequences).
            *   A [Byte Sequence](https://www.rfc-editor.org/rfc/rfc8941.html#name-byte-sequences) is delimited with colons and encoded using [base64](https://www.rfc-editor.org/rfc/rfc4648.html).
            *   The sequence of bytes obtained by decoding the [base64](https://www.rfc-editor.org/rfc/rfc4648.html) from the [Byte Sequence](https://www.rfc-editor.org/rfc/rfc8941.html#name-byte-sequences) must be valid [UTF-8](https://www.rfc-editor.org/rfc/rfc3629.html).
            *   For example:
                *    `:aGVsbG8K:` encodes "hello\n" in a [UTF-8](https://www.rfc-editor.org/rfc/rfc3629.html) [Byte Sequence](https://www.rfc-editor.org/rfc/rfc8941.html#name-byte-sequences) (where "\n" is the newline character).
                *    `:8J+YgA==:` encodes "😀" in a [UTF-8](https://www.rfc-editor.org/rfc/rfc3629.html) [Byte Sequence](https://www.rfc-editor.org/rfc/rfc8941.html#name-byte-sequences).
            *   Remember that results returned via `get()` are [UTF-16](https://www.rfc-editor.org/rfc/rfc2781.html) [DOMStrings](https://webidl.spec.whatwg.org/#idl-DOMString).
*  Performing operations via response headers requires a prior opt-in via a corresponding HTTP request header `Sec-Shared-Storage-Writable: ?1`.
*  The request header can be sent along with `fetch` requests via specifying an option: `fetch(<url>, {sharedStorageWritable: true})`.
*  The request header can alternatively be sent on document or image requests either 
    *   via specifying a boolean content attribute, e.g.: 
        *   `<iframe src=[url] sharedstoragewritable></iframe>`
        *    `<img src=[url] sharedstoragewritable>`
    *   or via an equivalent boolean IDL attribute, e.g.:
        *   `iframe.sharedStorageWritable = true`
        *   `img.sharedStorageWritable = true`.
*  Redirects will be followed, and the request header will be sent to the host server for the redirect URL.
*  The origin used for Shared Storage is that of the server that sends the `Shared-Storage-Write` response header(s).
    *   If there are no redirects, this will be the origin of the request URL.
    *   If there are redirects, the origin of the redirect URL that is accompanied by the `Shared-Storage-Write` response header(s) will be used.
*  The response header will only be honored if the corresponding request included the request header: `Sec-Shared-Storage-Writable: ?1`.
*  See example usage below.



## Example scenarios

The following describe example use cases for Shared Storage and we welcome feedback on additional use cases that Shared Storage may help address.

### Cross-site reach measurement

Measuring the number of users that have seen an ad.


In the ad’s iframe:


```js
await window.sharedStorage.worklet.addModule('reach.js');
await window.sharedStorage.run('send-reach-report', {
  // optional one-time context
  data: { campaignId: '1234' },
});
```

Worklet script (i.e. `reach.js`):


```js
class SendReachReportOperation {
  async run(data) {
    const reportSentForCampaign = `report-sent-${data.campaignId}`;

    // Compute reach only for users who haven't previously had a report sent for this campaign.
    // Users who had a report for this campaign triggered by a site other than the current one will
    // be skipped.
    if (await this.sharedStorage.get(reportSentForCampaign) === 'yes') {
      return; // Don't send a report.
    }

    // The user agent will send the report to a default endpoint after a delay.
    privateAggregation.contributeToHistogram({
      bucket: data.campaignId,
      value: 128, // A predetermined fixed value; see Private Aggregation API explainer: Scaling values.
    });

    await this.sharedStorage.set(reportSentForCampaign, 'yes');
  }
}
register('send-reach-report', SendReachReportOperation);
```

### Creative selection by frequency

If an ad creative has been shown to the user too many times, a different ad should be selected.

In the advertiser's iframe:

```js
// Fetches two ads in a list. The second is the proposed ad to display, and the first 
// is the fallback in case the second has been shown to this user too many times.
const ads = await advertiser.getAds();

// Register the worklet module
await window.sharedStorage.worklet.addModule('creative-selection-by-frequency.js');

// Run the URL selection operation
const frameConfig = await window.sharedStorage.selectURL(
  'creative-selection-by-frequency', 
  ads.urls, 
  { 
    data: { 
      campaignId: ads.campaignId 
    },
    resolveToConfig: true,
  });

// Render the frame
document.getElementById('my-fenced-frame').config = frameConfig;
```

In the worklet script (`creative-selection-by-frequency.js`):

```js
class CreativeSelectionByFrequencyOperation {
  async run(data, urls) {
    // By default, return the default url (0th index).
    let index = 0;

    let count = await this.sharedStorage.get(data.campaignId);
    count = count ? parseInt(count) : 0;

    // If under cap, return the desired ad.
    if (count < 3) {
      index = 1;
      this.sharedStorage.set(data.campaignId, (count + 1).toString());
    }

    return index;
  }
}

register('creative-selection-by-frequency', CreativeSelectionByFrequencyOperation);
```


### _K_+ frequency measurement

By instead maintaining a counter in shared storage, the approach for cross-site reach measurement could be extended to _K_+ frequency measurement, i.e. measuring the number of users who have seen _K_ or more ads on a given browser, for a pre-chosen value of _K_. A unary counter can be maintained by calling `window.sharedStorage.append("freq", "1")` on each ad view. Then, the `send-reach-report` operation would only send a report if there are more than _K_ characters stored at the key `"freq"`. This counter could also be used to filter out ads that have been shown too frequently (similarly to the A/B example above).

### Reporting embedder context

In using the [Private Aggregation API](https://github.com/patcg-individual-drafts/private-aggregation-api) to report on advertisements within [fenced frames](https://github.com/wicg/fenced-frame/), for instance, we might report on viewability, performance, which parts of the ad the user engaged with, the fact that the ad showed up at all, and so forth. But when reporting on the ad, it might be important to tie it to some contextual information from the embedding publisher page, such as an event-level ID.

In a scenario where the input URLs for the [fenced frame](https://github.com/wicg/fenced-frame/) must be k-anonymous, e.g. if we create a [FencedFrameConfig](https://github.com/WICG/fenced-frame/blob/master/explainer/fenced_frame_config.md) from running a [Protected Audience auction](https://github.com/WICG/turtledove/blob/main/FLEDGE.md#2-sellers-run-on-device-auctions), it would not be a good idea to rely on communicating the event-level ID to the [fenced frame](https://github.com/wicg/fenced-frame/) by attaching an identifier to any of the input URLs, as this would make it difficult for any input URL(s) with the attached identifier to reach the k-anonymity threshold.  

Instead, before navigating the [fenced frame](https://github.com/wicg/fenced-frame/) to the auction's winning [FencedFrameConfig](https://github.com/WICG/fenced-frame/blob/master/explainer/fenced_frame_config.md) `fencedFrameConfig`, we could write the event-level ID to `fencedFrameConfig` using `fencedFrameConfig.setSharedStorageContext()` as in the example below. 

Subsequently, anything we've written to `fencedFrameConfig` through `setSharedStorageContext()` prior to the fenced frame's navigation to `fencedFrameConfig`, can be read via `sharedStorage.context` from inside a shared storage worklet created by the [fenced frame](https://github.com/wicg/fenced-frame/), or created by any of its same-origin children.

In the embedder page:

```js
// See https://github.com/WICG/turtledove/blob/main/FLEDGE.md for how to write an auction config.
const auctionConfig = { ... };

// Run a Protected Audience auction, setting the option to "resolveToConfig" to true. 
auctionConfig.resolveToConfig = true;
const fencedFrameConfig = await navigator.runAdAuction(auctionConfig);

// Write to the config any desired embedder contextual information as a string.
fencedFrameConfig.setSharedStorageContext("My Event ID 123");

// Navigate the fenced frame to the config.
document.getElementById('my-fenced-frame').config = fencedFrameConfig;
```

In the fenced frame (`my-fenced-frame`):

```js
// Save some information we want to report that's only available inside the fenced frame.
const frameInfo = { ... };

// Send a report using shared storage and private aggregation.
await window.sharedStorage.worklet.addModule('report.js');
await window.sharedStorage.run('send-report', {
  data: { info: frameInfo },
});
```

In the worklet script (`report.js`):

```js
class ReportingOperation {
  async run(data) {
    // Helper functions that map the embedder context to a predetermined bucket and the 
    // frame info to an appropriately-scaled value. 
    // See also https://github.com/patcg-individual-drafts/private-aggregation-api#examples
    function convertEmbedderContextToBucketId(context) { ... }
    function convertFrameInfoToValue(info) { ... }
    
    // The user agent sends the report to the reporting endpoint of the script's
    // origin (that is, the caller of `sharedStorage.run()`) after a delay.
    privateAggregation.contributeToHistogram({
      bucket: convertEmbedderContextToBucketId(sharedStorage.context) ,
      value: convertFrameInfoToValue(data.info)
    });
  }
}
register('send-report', ReportingOperation);
```

### Keeping a worklet alive for multiple operations

Callers may wish to run multiple worklet operations from the same context, e.g. they might select a URL and then send one or more aggregatable reports. To do so, they would need to use the `keepAlive: true` option when calling each of the worklet operations (except perhaps in the last call, if there was no need to extend the worklet's lifetime beyond that call).

As an example, in the embedder page:

```js
// Load the worklet module.
await window.sharedStorage.worklet.addModule('worklet.js');

// Select a URL, keeping the worklet alive.
const fencedFrameConfig = await window.selectURL(
  [
    {url: "blob:https://a.example/123…"},
    {url: "blob:https://b.example/abc…"}
  ],
  {
    data: { ... },
    keepAlive: true,
    resolveToConfig: true
  }
);

// Navigate a fenced frame to the resulting config.
document.getElementById('my-fenced-frame').config = fencedFrameConfig;

// Send some report, keeping the worklet alive.
await window.sharedStorage.run('report', {
  data: { ... },
  keepAlive: true,
});

// Send another report, allowing the worklet to close afterwards.
await window.sharedStorage.run('report', {
  data: { ... },
});

// From this point on, if we make any additional worklet calls, they will fail.
```

In the worklet script (`worklet.js`):

```js
class URLOperation {
  // See previous examples for how to write a `selectURL()` operation class.
  async run(urls, data) { ... }
}

class ReportOperation {
  // See previous examples for how to write a `run()` operation class.
  async run(data) { ... }
}

register('select-url', URLOperation);
register('report', ReportOperation);
```

### Using cross-origin worklets

There are currently three (3) different approaches to creating a worklet with cross-origin script.


1. Call `addModule()` with a cross-origin script. 

    In an "https://a.example" context in the embedder page:

    ```
    await sharedStorage.addModule("https://b.example/worklet.js");
    ```

    For any subsequent `run()` or `selectURL()` operation invoked on this worklet, the shared storage data for "https://a.example" (i.e. the context origin) will be used.

2. Call `createWorklet()` with a cross-origin script.

    In an "https://a.example" context in the embedder page:

    ```
    const worklet = await sharedStorage.createWorklet("https://b.example/worklet.js");
    ```

    For any subsequent `run()` or `selectURL()` operation invoked on this worklet, the shared storage data for "https://a.example" (i.e. the context origin) will be used.

3. Call `createWorklet()` with a cross-origin script, setting its `dataOption` to the worklet script's origin.

    In an "https://a.example" context in the embedder page:

    ```
    const worklet = await sharedStorage.createWorklet("https://b.example/worklet.js", {dataOrigin: "script-origin"});
    ```

    For any subsequent `run()` or `selectURL()` operation invoked on this worklet, the shared storage data for "https://b.example" (i.e. the worklet script origin) will be used.

### Writing to Shared Storage via response headers

For an origin making changes to their Shared Storage data at a point when they do not need to read the data, an alternative to using the Shared Storage JavaScript API is to trigger setter and/or deleter operations via the HTTP response header `Shared-Storage-Write` as in the examples below. 

In order to perform operations via response header, the origin must first opt-in via one of the methods below, causing the HTTP request header `Sec-Shared-Storage-Writable: ?1` to be added by the user agent if the request is eligible based on permissions checks. 

An origin `a.example` could initiate such a request in multiple ways.

On the client side, to initiate the request:
1. `fetch()` option:
    ```js
    fetch("https://a.example/path/for/updates", {sharedStorageWritable: true});
    ```
2. Content attribute option with an iframe (also possible with an img):
   ```
    <iframe src="https://a.example/path/for/updates" sharedstoragewritable></iframe>

    ```
3. IDL attribute option with an iframe (also possible with an img):
    ```js
    let iframe = document.getElementById("my-iframe");
    iframe.sharedStorageWritable = true;
    iframe.src = "https://a.example/path/for/updates";
    ```

On the server side, here is an example response header:
```text
Shared-Storage-Write: clear, set;key="hello";value="world";ignore_if_present, append;key="good";value="bye", delete;key="hello", set;key="all";value="done"
```

Sending the above response header would be equivalent to making the following calls in the following order on the client side, from either the document or a worklet:
```js
sharedStorage.clear();
sharedStorage.set("hello", "world", {ignoreIfPresent: true});
sharedStorage.append("good", "bye");
sharedStorage.delete("hello");
sharedStorage.set("all", "done");
```

## Worklets can outlive the associated document

After a document dies, the corresponding worklet (if running an operation) will continue to be kept alive for a maximum of two seconds to allow the pending operation(s) to execute. This gives more confidence that any end-of-page operations (e.g. reporting) are able to finish.

## Permissions Policy

Shared storage methods can be disallowed by the "shared-storage" [policy-controlled feature](https://w3c.github.io/webappsec-permissions-policy/#policy-controlled-feature). Its default allowlist is * (i.e. every origin).

The sharedStorage.selectURL() method can be disallowed by the "shared-storage-select-url" [policy-controlled feature](https://w3c.github.io/webappsec-permissions-policy/#policy-controlled-feature). Its default allowlist is * (i.e. every origin).

### Permissions Policy inside the shared storage worklet
The permissions policy inside the shared storage worklet will inherit the permissions policy of the associated document.

The [Private Aggregation API](https://github.com/patcg-individual-drafts/private-aggregation-api) will be controlled by the "private-aggregation" policy-controlled feature: within the shared storage worklet, if the "private-aggregation" policy-controlled feature is disabled, the `privateAggregation` methods will throw an exception.

## Data Retention Policy
Each key is cleared after thirty days of last write (`set` or `append` call). If `ignoreIfPresent` is true, the last write time is updated.

## Data Storage Limits
Shared Storage is not subject to the quota manager, as that would leak information across sites. Therefore we limit its size in the following way: Shared Storage allows each origin up to 5 Megabytes. 

## Dependencies

This API is dependent on the following other proposals:



*   [Fenced frames](https://github.com/WICG/fenced-frame) (and the associated concept of [fenced frame configs](https://github.com/WICG/fenced-frame/blob/master/explainer/fenced_frame_config.md)) to render the chosen URL without leaking the choice to the top-level document.
*   [Private Aggregation API](https://github.com/alexmturner/private-aggregation-api) to send aggregatable reports for processing in the private, secure [aggregation service](https://github.com/WICG/conversion-measurement-api/blob/main/AGGREGATION_SERVICE_TEE.md). Details and limitations are explored in the linked explainer.


## Output gates and privacy

The privacy properties of shared storage are enforced through limited output. So we must protect against any unintentional output channels, as well as against abuse of the intentional output channels.


### URL selection

The worklet selects from a small list of (up to 8) URLs, each in its own dictionary with optional reporting metadata. The chosen URL is stored in a fenced frame config as an opaque form that can only be read by a [fenced frame](https://github.com/WICG/fenced-frame); the embedder does not learn this information. The chosen URL represents up to log2(num urls) bits of cross-site information (as measured according to [information theory](https://en.wikipedia.org/wiki/Entropy_(information_theory))). Once the Fenced Frame receives a user gesture and navigates to its destination page, the information within the fenced frame leaks to the destination page. To limit the rate of leakage of this data, there is a bit budget applied to the output gate. If the budget is exceeded, the selectURL() will return the default (0th index) URL.

selectURL() can be called in a top-level fenced frame, but not from within a nested fenced frame. This is to prevent leaking lots of bits all at once via selectURL() chaining (i.e. a fenced frame can call selectURL() to add a few more bits to the fenced frame's current URL and render the result in a nested fenced frame). Use cases that will benefit from selectURL() being allowed from inside the top level fenced frame: [issue](https://github.com/WICG/fenced-frame/issues/44).

#### Budgeting
The rate of leakage of cross-site data need to be constrained. Therefore, we propose that there be a daily budget on how many bits of cross-site data can be leaked by the API per [site](https://html.spec.whatwg.org/multipage/browsers.html#site). Note that each time a Fenced Frame is clicked on and navigates the top frame, up to log2(|urls|) [bits of information](https://en.wikipedia.org/wiki/Entropy_(information_theory)) can potentially be leaked for each selectURL() involved in the creation of the Fenced Frame. Therefore, Shared Storage will deduct that log2(|urls|) bits from the Shared Storage worklet's [site](https://html.spec.whatwg.org/multipage/browsers.html#site)'s budget at that point. If the sum of the deductions from the last 24 hours exceed a threshold, then further selectURL()s will return the default value (the first url in the list) until some budget is freed up.

Why do we assume that log2(|urls|) bits of cross-site information are leaked by a call to `selectURL`? Because the embedder (the [site](https://html.spec.whatwg.org/multipage/browsers.html#site) calling `selectURL`) is providing a list of urls to choose from using cross-site information. If `selectURL` were abused to leak the first few bits of the user's cross-site identity, then, with 8 URLs to choose from, they could leak the first 3 bits of the id (e.g., imagine urls: https://example.com/id/000, https://example.com/id/001, https://example.com/id/010, ..., https://example.com/id/111). One can leak at most log2(|urls|) bits, and so that is what we deduct from the budget, but only after the fenced frame navigates the top page which is when its data can be communicated.

##### Budget Details
The budgets for bits of entropy for Shared Storage are as follows.

###### Long Term Budget

In the long term, `selectURL()` will leak bits of entropy on top-level navigation (e.g., a tab navigates). Therefore it is necessary to impose a budget for this leakage.

* There is a 12 bit daily per-[site](https://html.spec.whatwg.org/multipage/browsers.html#site) budget for `selectURL()`, to be queried on each `selectURL()` call for sufficient budget and charged on navigation. This is subject to change.
* The cost of a `selectURL()` call is log2(number of urls to `selectURL()` call) bits. This cost is only logged once the fenced frame holding the selected URL navigates the top frame. e.g., if the fenced frame can't communicate its contents (doesn't navigate), then there is no budget cost for that call to`selectURL()`.
* The remaining budget at any given time for a [site](https://html.spec.whatwg.org/multipage/browsers.html#site) is 12 - (the sum of the log of budget deductions from the past 24 hours).
* If the remaining budget is less than log2(number of urls in `selectURL()` call), the default URL is returned and 1 bit is logged if the fenced frame is navigated.

###### Short Term Budgets

In the short term, we have event-level reporting and less-restrictive [fenced frames](https://github.com/WICG/fenced-frame), which allow further leakage; thus it is necessary to impose additional limits. On top of the navigation bit budget described above, there will be two more budgets, each maintained on a per top-level navigation basis. The bit values for each call to `selectURL()` are calculated in the same way as detailed for the navigation bit budget.

* Each page load will have a per-[site](https://html.spec.whatwg.org/multipage/browsers.html#site) bit budget of 6 bits for `selectURL()` calls. At the start of a new top-level navigation, this budget will refresh.
* Each page load will also have an overall bit budget of 12 bits for `selectURL()`. This budget will be contributed to by all sites on the page. As with the per-[site](https://html.spec.whatwg.org/multipage/browsers.html#site) per-page load bit budget, this budget will refresh when the top frame navigates.

#### Enrollment and Attestation
Use of Shared Storage requires [enrollment](https://github.com/privacysandbox/attestation/blob/main/how-to-enroll.md) and [attestation](https://github.com/privacysandbox/attestation/blob/main/README.md#core-privacy-attestations) via the [Privacy Sandbox enrollment attestation model](https://github.com/privacysandbox/attestation/blob/main/README.md).

For each method in the Shared Storage API surface, a check will be performed to determine whether the calling [site](https://html.spec.whatwg.org/multipage/browsers.html#site) is [enrolled](https://github.com/privacysandbox/attestation/blob/main/how-to-enroll.md) and [attested](https://github.com/privacysandbox/attestation/blob/main/README.md#core-privacy-attestations). In the case where the [site](https://html.spec.whatwg.org/multipage/browsers.html#site) is not [enrolled](https://github.com/privacysandbox/attestation/blob/main/how-to-enroll.md) and [attested](https://github.com/privacysandbox/attestation/blob/main/README.md#core-privacy-attestations), the promise returned by the method is rejected.

#### Event Level Reporting
In the long term we'd like all reporting via Shared Storage to happen via the Private Aggregation output gate (or some additional noised reporting gate). We understand that in the short term it may be necessary for the industry to continue to use event-level reporting as they transition to more private reporting. Event-level reporting for content selection (`selectURL()`) will be available until at least 2026, and we will provide substantial notice for developers before the transition takes place.

Event level reports work in a way similar to how they work in Protected AUdience. First, when calling selectURL, the caller adds a `reportingMetadata` optional dict to the URLs that they wish to send reports for, such as:
```javascript
sharedStorage.selectURL(
    "test-url-selection-operation",
    [{url: "fenced_frames/title0.html"},
     {url: "fenced_frames/title1.html",
         reportingMetadata: {'click': "fenced_frames/report1.html",
             'visible': "fenced_frames/report2.html"}}]);
```
In this case, when in the fenced frame, event types are defined for `click` and `visibility`. Once the fenced frame is ready to send a report, it can call something like:

```javascript
window.fence.reportEvent({eventType: 'visible',
    eventData: JSON.stringify({'duration': duration}), 
    destination: ['shared-storage-select-url']});
```
and it will send a POST message with the eventData. See the [fenced frame reporting document](https://github.com/WICG/turtledove/blob/main/Fenced_Frames_Ads_Reporting.md) for more details.

### Private aggregation

Arbitrary cross-site data can be embedded into any aggregatable report, but that data is only readable via the aggregation service. Private aggregation protects the data with differential privacy. In order to adhere to the chosen differential privacy parameters, there are limits on the total amount of value the origin's reports can provide per time-period. The details of these limits are explored in the API's [explainer](https://github.com/alexmturner/private-aggregation-api#privacy-and-security).


### Choice of output type

The output type when running an operation must be pre-specified to prevent data leakage through the choice. This is enforced with separate functions for each output type, i.e. `sharedStorage.selectURL()` and `sharedStorage.run()`.


### <a name = "default"></a>Default values

When `sharedStorage.selectURL()` doesn’t return a valid output (including throwing an error), the user agent returns the first default URL, to prevent information leakage. For `sharedStorage.run()`, there is no output, so any return value is ignored.


### Preventing timing attacks

Revealing the time an operation takes to run could also leak information. We avoid this by having `sharedStorage.run()` queue the operation and then immediately resolve the returned promise. For `sharedStorage.selectURL()`, the promise resolves into an [fenced frame config](https://github.com/WICG/fenced-frame/blob/master/explainer/fenced_frame_config.md) that contains the opaque URL that is mapped to the selected URL once the operation completes. A Fenced Frame can be created with the returned fenced frame config even before the selectURL operation has completed. The frame will wait for it to complete first.  Similarly, outside a worklet, `set()`, `remove()`, etc. return promises that resolve after queueing the writes. Inside a worklet, these writes join the same queue but their promises only resolve after completion.


## Possibilities for extension


### Allowing noised data as output to the embedder
We could consider allowing the worklet to send data directly to the embedder, with some local differential privacy guarantees. These might look similar to the differential privacy protections that we apply in the Private Aggregation API. 

### Interactions between worklets

Communication between worklets is not possible in the initial design. However, adding support for this would enable multiple origins to flexibly share information without needing a dedicated origin for that sharing. Relatedly, allowing a worklet to create other worklets might be useful.


### Registering event handlers

We could support event handlers in future iterations. For example, a handler could run a previously registered operation when a given key is modified (e.g. when an entry is updated via a set or append call):


```js
sharedStorage.addEventListener(
  'key' /* event_type */,
  'operation-to-run' /* operation_name */,
  { key: 'example-key', actions: ['set', 'append'] } /* options */);
```



## Acknowledgements

Many thanks for valuable feedback and advice from:

Victor Costan,
Christian Dullweber,
Charlie Harrison,
Jeff Kaufman,
Rowan Merewood,
Marijn Kruisselbrink,
Nasko Oskov,
Evgeny Skvortsov,
Michael Tomaine,
David Turner,
David Van Cleve,
Zheng Wei,
Mike West.
