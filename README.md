# Shared Storage API Explainer

Authors: Alex Turner, Camillia Smith Barnes, Josh Karlin, Yao Xiao


## Introduction 

In order to prevent cross-site user tracking, browsers are [partitioning](https://blog.chromium.org/2020/01/building-more-private-web-path-towards.html) all forms of storage (cookies, localStorage, caches, etc) by top-frame site. But, there are many legitimate use cases currently relying on unpartitioned storage that will vanish without the help of new web APIs. We’ve seen a number of APIs proposed to fill in these gaps (e.g., [Conversion Measurement API](https://github.com/WICG/conversion-measurement-api), [Private Click Measurement](https://github.com/privacycg/private-click-measurement), [Storage Access](https://developer.mozilla.org/en-US/docs/Web/API/Storage_Access_API), [Private State Tokens](https://github.com/WICG/trust-token-api), [TURTLEDOVE](https://github.com/WICG/turtledove), [FLoC](https://github.com/WICG/floc)) and some remain (including cross-origin A/B experiments and user measurement). We propose a general-purpose, low-level API that can serve a number of these use cases.

The idea is to provide a storage API (named Shared Storage) that is intentionally not partitioned by top-frame site (though still partitioned by context origin of course!). To limit cross-site reidentification of users, data in Shared Storage may only be read in a restricted environment that has carefully constructed output gates. Over time, we hope to design and add additional gates.

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

// opaqueURL will be of the form urn:uuid and will be created by privileged code to
// avoid leaking the chosen input URL back to the document.

const opaqueURL = await window.sharedStorage.selectURL(
  'select-url-for-experiment',
  [
    {url: "blob:https://a.example/123…", reportingMetadata: {"click": "https://report.example/1..."}},
    {url: "blob:https://b.example/abc…", reportingMetadata: {"click": "https://report.example/a..."}},
    {url: "blob:https://c.example/789…"}
  ],
  { data: { name: 'experimentA' } }
);

document.getElementById('my-fenced-frame').src = opaqueURL;
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


While the worklet script outputs the chosen index for `urls`, note that the browser process converts the index into a non-deterministic [opaque URL](https://github.com/shivanigithub/fenced-frame/blob/master/explainer/opaque_src.md), which can only be read or rendered in a [fenced frame](https://github.com/shivanigithub/fenced-frame). Because of this, the `a.example` iframe cannot itself work out which ad was chosen. Yet, it is still able to customize the ad it rendered based on this protected information.


## Goals

This API intends to support a wide array of use cases, replacing many of the existing uses of third-party cookies. These include recording (aggregate) statistics — e.g. demographics, reach, interest, anti-abuse, and conversion measurement — A/B experimentation, different documents depending on if the user is logged in, and interest-based selection. Enabling these use cases will help to support a thriving open web. Additionally, by remaining generic and flexible, this API aims to foster continued growth, experimentation, and rapid iteration in the web ecosystem and to avert ossification and unnecessary rigidity.

However, this API also seeks to avoid the privacy loss and abuses that third-party cookies have enabled. In particular, it aims to limit cross-site reidentification of a user. Wide adoption of this more privacy-preserving API by developers will make the web much more private by default in comparison to the third-party cookies it helps to replace.


## Related work

There have been multiple privacy proposals ([SPURFOWL](https://github.com/AdRoll/privacy/blob/main/SPURFOWL.md), [SWAN](https://github.com/1plusX/swan), [Aggregated Reporting](https://github.com/csharrison/aggregate-reporting-api)) that have a notion of write-only storage with limited output. This API is similar to those, but tries to be more general to support a greater number of output gates and use cases. We’d also like to acknowledge the [KV Storage](https://github.com/WICG/kv-storage) explainer, to which we turned for API-shape inspiration.


## Proposed API surface


### Outside the worklet
The setter methods (`set`, `append`, `delete`, and `clear`) should be made generally available across most any context. That includes top-level documents, iframes, shared storage worklets,  fledge worklets, service workers, dedicated workers, etc.

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
*   `window.sharedStorage.worklet.addModule(url)`
    *   Loads and adds the module to the worklet (i.e. for registering operations).
    *   Operations defined by one context are not invokable by any other contexts.
    *   Due to concerns of poisoning and using up the origin's budget ([issue](https://github.com/pythagoraskitty/shared-storage/issues/2)), the shared storage script's origin must match that of the context that created it. Redirects are also not allowed. 
*   `window.sharedStorage.run(name, options)`,  \
`window.sharedStorage.selectURL(name, urls, options)`, …
    *   Runs the operation previously registered by `register()` with matching `name`. Does nothing if there’s no matching operation.
    *   Each operation returns a promise that resolves when the operation is queued:
        *   `run()` returns a promise that resolves into `undefined`.
        *   `selectURL()` returns a promise that resolves into an [opaque URL](https://github.com/shivanigithub/fenced-frame/blob/master/explainer/opaque_src.md) for the URL selected from `urls`. 
            *   `urls` is a list of dictionaries, each containing a candidate URL `url` and optional reporting metadata (a dictionary, with the key being the event type and the value being the reporting URL; identical to FLEDGE's [registerAdBeacon()](https://github.com/WICG/turtledove/blob/main/Fenced_Frames_Ads_Reporting.md#registeradbeacon) parameter), with a max length of 8.
                *    The `url` of the first dictionary in the list is the `default URL`. This is selected if there is a script error, or if there is not enough budget remaining, or if the selected URL is not yet k-anonymous.
                *    The selected URL will be checked to see if it is k-anonymous. If it is not, its k-anonymity will be incremented, but the `default URL` will be returned.
                *    The reporting metadata will be used in the short-term to allow event-level reporting via `window.fence.reportEvent()` as described in the [FLEDGE explainer](https://github.com/WICG/turtledove/blob/main/Fenced_Frames_Ads_Reporting.md).
            *    There will be a per-origin (the origin of the Shared Storage worklet) budget for `selectURL`. This is to limit the rate of leakage of cross-site data learned from the selectURL to the destination pages that the resulting Fenced Frames navigate to. Each time a Fenced Frame navigates the top frame, for each `selectURL()` involved in the creation of the Fenced Frame, log(|`urls`|) bits will be deducted from the corresponding origin’s budget. At any point in time, the current budget remaining will be calculated as `max_budget - sum(deductions_from_last_24hr)`
    *   Options can include `data`, an arbitrary serializable object passed to the worklet.


### In the worklet, during `addModule()`



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
*   Functions exposed by the [Private Aggregation API](https://github.com/alexmturner/private-aggregation-api), e.g. `privateAggregation.sendHistogramReport()`.
    *   These functions construct and then send an aggregatable report for the private, secure [aggregation service](https://github.com/WICG/conversion-measurement-api/blob/main/AGGREGATION_SERVICE_TEE.md).
    *   The report contents (e.g. key, value) are encrypted and sent after a delay. The report can only be read by the service and processed into aggregate statistics.
*   Unrestricted access to identifying operations that would normally use up part of a page’s [privacy budget](http://github.com/bslassey/privacy-budget), e.g. `navigator.userAgentData.getHighEntropyValues()`


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
    privateAggregation.sendHistogramReport({
      bucket: data.campaignId,
      value: 128, // A predetermined fixed value; see Private Aggregation API explainer: Scaling values.
    });

    await this.sharedStorage.set(reportSentForCampaign, 'yes');
  }
}
register('send-reach-report', SendReachReportOperation);
```

### Frequency Capping

If an ad creative has been shown to the user too many times, fall back to a default option.

In the advertiser's iframe:

```js
// Fetches two ads in a list. The second is the proposed ad to display, and the first 
// is the fallback in case the second has been shown to this user too many times.
const ads = await advertiser.getAds();

await window.sharedStorage.worklet.addModule('frequency-cap.js');
const opaqueURL = await window.sharedStorage.selectURL(
  'frequency-cap', 
  ads.urls, 
  { data: { campaignId: ads.campaignId }});
document.getElementById('my-fenced-frame').src = opaqueURL;
```

In the worklet script (`frequency-cap.js`):

```js
class FrequencyCapOperation {
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
register('frequency-cap', FrequencyCapOperation);
```


### _K_+ frequency measurement

By instead maintaining a counter in shared storage, the approach for cross-site reach measurement could be extended to _K_+ frequency measurement, i.e. measuring the number of users who have seen _K_ or more ads on a given browser, for a pre-chosen value of _K_. A unary counter can be maintained by calling `window.sharedStorage.append("freq", "1")` on each ad view. Then, the `send-reach-report` operation would only send a report if there are more than _K_ characters stored at the key `"freq"`. This counter could also be used to filter out ads that have been shown too frequently (similarly to the A/B example above).

### Reporting embedder context

In using the [Private Aggregation API](https://github.com/patcg-individual-drafts/private-aggregation-api) to report on advertisements within [fenced frames](https://github.com/wicg/fenced-frame/), for instance, we might report on viewability, performance, which parts of the ad the user engaged with, the fact that the ad showed up at all, and so forth. But when reporting on the ad, it might be important to tie it to some contextual information from the embedding publisher page, such as an event-level ID.

In a scenario where the input URLs for the [fenced frame](https://github.com/wicg/fenced-frame/) must be k-anonymous, e.g. if we create a [FencedFrameConfig](https://github.com/WICG/fenced-frame/blob/master/explainer/fenced_frame_config.md) from running a [FLEDGE auction](https://github.com/WICG/turtledove/blob/main/FLEDGE.md#2-sellers-run-on-device-auctions), it would not be a good idea to rely on communicating the event-level ID to the [fenced frame](https://github.com/wicg/fenced-frame/) by attaching an identifier to any of the input URLs, as this would make it difficult for any input URL(s) with the attached identifier to reach the k-anonymity threshold.  

Instead, before navigating the [fenced frame](https://github.com/wicg/fenced-frame/) to the auction's winning [FencedFrameConfig](https://github.com/WICG/fenced-frame/blob/master/explainer/fenced_frame_config.md) `fencedFrameConfig`, we could write the event-level ID to `fencedFrameConfig` using `fencedFrameConfig.setSharedStorageContext()` as in the example below. 

Subsequently, anything we've written to `fencedFrameConfig` through `setSharedStorageContext()` prior to the fenced frame's navigation to `fencedFrameConfig`, can be read via `sharedStorage.context` from inside a shared storage worklet created by the [fenced frame](https://github.com/wicg/fenced-frame/), or created by any of its same-origin children.

In the embedder page:

```js
// See https://github.com/WICG/turtledove/blob/main/FLEDGE.md for how to write an auction config.
const auctionConfig = { ... };

// Run a FLEDGE auction, setting the option to "resolveToConfig" to true. 
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
    privateAggregation.sendHistogramReport({
      bucket: convertEmbedderContextToBucketId(sharedStorage.context) ,
      value: convertFrameInfoToValue(data.info)
    });
  }
}
register('send-report', ReportingOperation);
```

## Keep-alive worklet

After a document dies, the corresponding worklet will be kept alive for maximum two seconds to allow the pending operations to execute. This gives more confidence that the end-of-page operations (e.g. reporting) are able to finish.

## Permissions Policy

Shared storage methods can be disallowed by the "shared-storage" [policy-controlled feature](https://w3c.github.io/webappsec-permissions-policy/#policy-controlled-feature). Its default allowlist is * (i.e. every origin).

The sharedStorage.selectURL() method can be disallowed by the "shared-storage-select-url" [policy-controlled feature](https://w3c.github.io/webappsec-permissions-policy/#policy-controlled-feature). Its default allowlist is * (i.e. every origin).

### Permissions Policy inside the shared storage worklet
The permissions policy inside the shared storage worklet will inherit the permissions policy of the associated document.

The [Private Aggregation API](https://github.com/patcg-individual-drafts/private-aggregation-api) will be controlled by the "private-aggregation" policy-controlled feature: within the shared storage worklet, if the "private-aggregation" policy-controlled feature is disabled, the `privateAggregation` methods will throw an exception.

## Data Retention Policy
Each key is cleared after thirty days of last write (`set` or `append` call). If `ignoreIfPresent` is true, the last write time is updated.

## Data Storage Limits
Shared Storage is not subject to the quota manager, as that would leak information across sites. Therefore we limit its size in the following way: Shared Storage allows each origin up to 10,000 key/value pairs, with each key and value limited to a maximum of 1024 characters apiece. 

## Dependencies

This API is dependent on the following other proposals:



*   [Fenced frames](https://github.com/shivanigithub/fenced-frame/) (and the associated concept of [opaque URLs](https://github.com/shivanigithub/fenced-frame/blob/master/OpaqueSrc.md)) to render the chosenURL without leaking the choice to the top-level document.
*   [Private Aggregation API](https://github.com/alexmturner/private-aggregation-api) to send aggregatable reports for processing in the private, secure [aggregation service](https://github.com/WICG/conversion-measurement-api/blob/main/AGGREGATION_SERVICE_TEE.md). Details and limitations are explored in the linked explainer.


## Output gates and privacy

The privacy properties of shared storage are enforced through limited output. So we must protect against any unintentional output channels, as well as against abuse of the intentional output channels.


### URL selection

The worklet selects from a small list of (up to 8) URLs, each in its own dictionary with optional reporting metadata. The chosen URL is stored in an opaque URL that can only be read within a [fenced frame](https://github.com/shivanigithub/fenced-frame); the embedder does not learn this information. The chosen URL represents up to log2(num urls) bits of cross-site information. The URL must also be k-anonymous, in order to prevent much 1p data from also entering the Fenced Frame. Once the Fenced Frame receives a user gesture and navigates to its destination page, the information within the fenced frame leaks to the destination page. To limit the rate of leakage of this data, there is a bit budget applied to the output gate. If the budget is exceeded, the selectURL() will return the default (0th index) URL.

selectURL() can be called in a top-level fenced frame, but not from within a nested fenced frame. This is to prevent leaking lots of bits all at once via selectURL() chaining (i.e. a fenced frame can call selectURL() to add a few more bits to the fenced frame's current URL and render the result in a nested fenced frame). Use cases that will benefit from selectURL() being allowed from inside the top level fenced frame: [issue](https://github.com/WICG/fenced-frame/issues/44).

selectURL() is only availale in fenced frames that originate from shared storage (i.e. not available in [FLEDGE](https://github.com/WICG/turtledove/blob/main/FLEDGE.md) generated fenced frames).

#### Budgeting
The rate of leakage of cross-site data need to be constrained. Therefore, we propose that there be a daily budget on how many bits of cross-site data can be leaked by the API per origin. Note that each time a Fenced Frame is clicked on and navigates the top frame, up to log2(|urls|) bits of information can potentially be leaked for each selectURL() involved in the creation of the Fenced Frame. Therefore, Shared Storage will deduct that log2(|urls|) bits from each of the Shared Storage worklet's origin at that point. If the sum of the deductions from the last 24 hours exceed a threshold, then further selectURL()s will return the default value (the first url in the list) until some budget is freed up.

Why do we assume that log2(|urls|) bits of cross-site information are leaked by a call to `selectURL`? Because the embedder (the origin calling `selectURL`) is providing a list of urls to choose from using cross-site information. If `selectURL` were abused to leak the first few bits of the user's cross-site identity, then, with 8 URLs to choose from, they could leak the first 3 bits of the id (e.g., imagine urls: https://example.com/id/000, https://example.com/id/001, https://example.com/id/010, ..., https://example.com/id/111). One can leak at most log2(|urls|) bits, and so that is what we deduct from the budget, but only after the fenced frame navigates the top page which is when its data can be communicated.

##### Budget Details
* There is a 12 bit budget for selectURL to start with. This is subject to change.
* The cost of a selectURL call is log2(number of urls to selectURL call) bits. This cost is only logged once the fenced frame holding the selected URL navigates the top frame. e.g., if the fenced frame can't communicate its contents (doesn't navigate), then there is no budget cost for that call to selectURL.
* The remaining budget at any given time for an origin is 12 - (the sum of the log of budget deductions from the past 24 hours).
* If the remaining budget is less than log2(number of urls in selectURL call), the default URL is returned and 1 bit is logged if the fenced frame is navigated.

#### Event Level Reporting
In the long term we'd like all reporting via Shared Storage to happen via the Private Aggregation output gate. We understand that in the short term it may be necessary for the industry to continue to use event-level reporting as they transition to aggregate reporting. 

Event level reports work in a way similar to how they work in FLEDGE. First, when calling selectURL, the caller adds a `reportingMetadata` optional dict to the URLs that they wish to send reports for, such as:
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

##### Event Level Reporting Limits
This event-level reporting will allow for the embedding page's 1p data to be combined with the log2(num urls in selectURL) bits of third-party shared-storage data as soon as the report is sent. Since this can be used to build up a lot of information quite quickly, we're imposing some limits on event-level reporting while it's available. That is, event-level reporting via `reportEvent` can only be called up to three times per top-level page navigation.

#### K-anonymity Details
Like [FLEDGE](https://github.com/WICG/turtledove/blob/main/FLEDGE.md), there will be a k-anonymity service to ensure that the selected URL has met its k-anonymity threshold. If it has not, its count will be increased by 1 on the k-anonymity server, but the default URL will be returned. This makes it possible to bootstrap new URLs.


### Private aggregation

Arbitrary cross-site data can be embedded into any aggregatable report, but that data is only readable via the aggregation service. Private aggregation protects the data with differential privacy. In order to adhere to the chosen differential privacy parameters, there are limits on the total amount of value the origin's reports can provide per time-period. The details of these limits are explored in the API's [explainer](https://github.com/alexmturner/private-aggregation-api#privacy-and-security).


### Choice of output type

The output type when running an operation must be pre-specified to prevent data leakage through the choice. This is enforced with separate functions for each output type, i.e. `sharedStorage.selectURL()` and `sharedStorage.run()`.


### <a name = "default"></a>Default values

When `sharedStorage.selectURL()` doesn’t return a valid output (including throwing an error), the user agent returns the first default URL, to prevent information leakage. For `sharedStorage.run()`, there is no output, so any return value is ignored.


### Preventing timing attacks

Revealing the time an operation takes to run could also leak information. We avoid this by having `sharedStorage.run()` queue the operation and then immediately resolve the returned promise. For `sharedStorage.selectURL()`, the promise resolves into an [opaque URL](https://github.com/shivanigithub/fenced-frame/blob/master/OpaqueSrc.md) that is mapped to the selected URL once the operation completes. A Fenced Frame can be created with the returned opaque URL even before the selectURL operation has completed. The frame will wait for it to complete first.  Similarly, outside a worklet, `set()`, `remove()`, etc. return promises that resolve after queueing the writes. Inside a worklet, these writes join the same queue but their promises only resolve after completion.


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
