# Shared Storage API Explainer

Authors: Alex Turner, Camillia Smith Barnes, Josh Karlin, Yao Xiao


## Introduction

In order to prevent cross-site user tracking, browsers are [partitioning](https://blog.chromium.org/2020/01/building-more-private-web-path-towards.html) all forms of storage (cookies, localStorage, caches, etc). But, there are many legitimate use cases currently relying on unpartitioned storage that will vanish without the help of new web APIs. We’ve seen a number of APIs proposed to fill in these gaps (e.g., [Conversion Measurement API](https://github.com/WICG/conversion-measurement-api), [Private Click Measurement](https://github.com/privacycg/private-click-measurement), [Storage Access](https://developer.mozilla.org/en-US/docs/Web/API/Storage_Access_API), [Trust Tokens](https://github.com/WICG/trust-token-api), [TURTLEDOVE](https://github.com/WICG/turtledove), [FLoC](https://github.com/WICG/floc)) and some remain (including cross-origin A/B experiments and user measurement). We propose a general-purpose, low-level API that can serve a number of these use cases.

The idea is to provide a storage API (named Shared Storage) that is intended to be unpartitioned. Origins can write to it from their own contexts on any page. To prevent cross-site tracking of users,  data in Shared Storage may only be read in a restricted environment that has carefully constructed output gates. Over time, we hope to design and add additional gates.

### Demonstration

You can [try it out](https://shared-storage-demo.web.app/) using Chrome 104+ (currently in canary and dev channels as of June 7th 2022).


### Simple example: Consistent A/B experiments across sites

A third-party, `a.example`, wants to randomly assign users to different groups (e.g. experiment vs control) in a way that is consistent cross-site.

To do so, `a.example` writes a seed to its shared storage (which is not added if already present). `a.example` then registers and runs an operation in the shared storage [worklet](https://developer.mozilla.org/en-US/docs/Web/API/Worklet) that assigns the user to a group based on the seed and the experiment name and chooses the appropriate ad for that group.

In an `a.example` document:


```js
function generateSeed() { … }
await window.sharedStorage.worklet.addModule("experiment.js");

// Only write a cross-site seed to a.example's storage if there isn't one yet.
window.sharedStorage.set("seed", generateSeed(), {ignoreIfPresent: true});

// opaqueURL will be of the form urn:uuid and will be created by privileged code to
// avoid leaking the chosen input URL back to the document.
var opaqueURL = await window.sharedStorage.selectURL(
  "select-url-for-experiment",
  [{url: "blob:https://a.example/123…", report_event: "click", report_url: "https://report.example/1..."},
   {url: "blob:https://b.example/abc…", report_event: "click", report_url: "https://report.example/a..."},
   {url: "blob:https://c.example/789…"}],
  {data: {name: "experimentA"}});

document.getElementById("my-fenced-frame").src = opaqueURL;
```


Worklet script (i.e. `experiment.js`):


```js
class SelectURLOperation {
  function hash(experimentName, seed) { … }

  async function run(data, urls) {
    let seed = await this.sharedStorage.get("seed");
    return hash(data["name"], seed) % urls.length;
  }
}
register("select-url-for-experiment", SelectURLOperation);
```


While the worklet script outputs the chosen index for `urls`, note that the browser process converts the index into a non-deterministic [opaque URL](https://github.com/shivanigithub/fenced-frame/blob/master/explainer/opaque_src.md), which can only be read or rendered in a [fenced frame](https://github.com/shivanigithub/fenced-frame). Because of this, the `a.example` iframe cannot itself work out which ad was chosen. Yet, it is still able to customize the ad it rendered based on this protected information.


## Goals

This API intends to support a wide array of use cases, replacing many of the existing uses of third-party cookies. These include recording (aggregate) statistics — e.g. demographics, reach, interest, and conversion measurement — A/B experimentation, different documents depending on if the user is logged in, and interest-based selection. Enabling these use cases will help to support a thriving open web. Additionally, by remaining generic and flexible, this API aims to foster continued growth, experimentation, and rapid iteration in the web ecosystem and to avert ossification and unnecessary rigidity.

However, this API also seeks to avoid the privacy loss and abuses that third-party cookies have enabled. In particular, it aims to prevent off-browser cross-site recognition of a user. Wide adoption of this more privacy-preserving API by developers will make the web much more private by default in comparison to the third-party cookies it helps to replace.


## Related work

There have been multiple privacy proposals ([SPURFOWL](https://github.com/AdRoll/privacy/blob/main/SPURFOWL.md), [SWAN](https://github.com/1plusX/swan), [Aggregated Reporting](https://github.com/csharrison/aggregate-reporting-api)) that have a notion of write-only storage with limited output. This API is similar to those, but tries to be more general to support a greater number of output gates and use cases. We’d also like to acknowledge the [KV Storage](https://github.com/WICG/kv-storage) explainer, to which we turned for API-shape inspiration.


## Proposed API surface


### Outside the worklet



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
            *   `urls` is a list of dictionaries, each containing a candidate URL `url` and optional reporting metadata (a string `report_event` and a URL `report_url`), with a max length of 8.
                *    The `url` of the first dictionary in the list is the `default URL`. This is selected if there is a script error, or if there is not enough budget remaining, or if the selected URL is not yet k-anonymous.
                *    The selected URL will be checked to see if it is k-anonymous. If it is not, its k-anonymity will be incremented, but the `default URL` will be returned.
                *    The reporting metadata will be used in the short-term to allow event-level reporting via `window.fence.reportEvent()` as described in the [FLEDGE explainer](https://github.com/WICG/turtledove/blob/main/Fenced_Frames_Ads_Reporting.md).
            *    There will be a per-origin (the origin of the Shared Storage worklet) budget for `selectURL`. This is to limit the rate of leakage of cross-site data learned from the selectURL to the destination pages that the resulting Fenced Frames navigate to. Each time a Fenced Frame built with an opaque URL output from a selectURL navigates the top frame, log(|`urls`|) bits will be deducted from the budget. At any point in time, the current budget remaining will be calculated as `max_budget - sum(deductions_from_last_24hr)` 
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
*   `sharedStorage.key(n)` and `sharedStorage.length()`
    *   Returns a promise that resolves into the `n`th key or the number of keys, respectively.
*   `sharedStorage.set(key, value, options)`, `sharedStorage.append(key, value)`, `sharedStorage.delete(key)`, and `sharedStorage.clear()`
    *   Same as outside the worklet, except that the promise returned only resolves into `undefined` when the operation has completed.
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
await window.sharedStorage.worklet.addModule("reach.js");
await window.sharedStorage.run("send-reach-report", {
  // optional one-time context
  data: {"campaign-id": "1234"}});
```

Worklet script (i.e. `reach.js`):


```js
class SendReachReportOperation {
  async function run(data) {
    const report_sent_for_campaign = "report-sent-" + data["campaign-id"];
    
    // Compute reach only for users who haven't previously had a report sent for this campaign.
    // Users who had a report for this campaign triggered by a site other than the current one will 
    // be skipped.
    if (await this.sharedStorage.get(report_sent_for_campaign) === "yes") {
      return;  // Don't send a report.
    }

    // The user agent will send the report to a default endpoint after a delay.
    privateAggregation.sendHistogramReport({
      bucket: data["campaign-id"];
      value: 128,  // A predetermined fixed value; see Private Aggregation API explainer: Scaling values.
      });
      
    await this.sharedStorage.set(report_sent_for_campaign, "yes");
  }
}
register("send-reach-report", SendReachReportOperation);
```

### Frequency Capping

If an an ad creative has been shown to the user too many times, fall back to a default option.

In the ad-tech's iframe:

```js
// Fetches two ads in a list. The second is the proposed ad to display, and the first 
// is the fallback in case the second has been shown to this user too many times.
var ads = await adtech.GetAds();

await window.sharedStorage.worklet.addModule("frequency_cap.js");
var opaqueURL = await window.sharedStorage.selectURL(
  "frequency-cap",
  ads.urls,
  {data: {campaignID: ads.campaignId}});
document.getElementById("my-fenced-frame").src = opaqueURL;
```

In the worklet script (`frequency_cap.js`):

```js
class FrequencyCapOperation {
  async function run(data, urls) {
    // By default, return the default url (0th index). 
    let result = 0;
    
    let count = await this.sharedStorage.get(data["campaign-id"]);
    count = count === "" ? 0 : parseInt(count);   
    
    // If under cap, return the desired ad.
    if (count < 3) {
      result = 1;
      this.sharedStorage.set(data["campaign-id"], (count + 1).toString());
    }
    
    return result;
}
register("frequency-cap", FrequencyCapOperation);
```


### _K_+ frequency measurement

By instead maintaining a counter in shared storage, the approach for cross-site reach measurement could be extended to _K_+ frequency measurement, i.e. measuring the number of users who have seen _K_ or more ads on a given browser, for a pre-chosen value of _K_. A unary counter can be maintained by calling `window.sharedStorage.append("freq", "1")` on each ad view. Then, the `send-reach-report` operation would only send a report if there are more than _K_ characters stored at the key `"freq"`. This counter could also be used to filter out ads that have been shown too frequently (similarly to the A/B example above).


## Keep-alive worklet

After a document dies, the corresponding worklet will be kept alive for maximum two seconds to allow the pending operations to execute. This gives more confidence that the end-of-page operations (e.g. reporting) are able to finish.

## Dependencies

This API is dependent on the following other proposals:



*   [Fenced frames](https://github.com/shivanigithub/fenced-frame/) (and the associated concept of [opaque URLs](https://github.com/shivanigithub/fenced-frame/blob/master/OpaqueSrc.md)) to render the chosenURL without leaking the choice to the top-level document.
*   [Private Aggregation API](https://github.com/alexmturner/private-aggregation-api) to send aggregatable reports for processing in the private, secure [aggregation service](https://github.com/WICG/conversion-measurement-api/blob/main/AGGREGATION_SERVICE_TEE.md). Details and limitations are explored in the linked explainer.


## Output gates and privacy

The privacy properties of shared storage are enforced through limited output. So we must protect against any unintentional output channels, as well as against abuse of the intentional output channels.


### URL selection

The worklet selects from a small list of (up to 8) URLs, each in its own dictionary with optional reporting metadata. The chosen URL is stored in an opaque URL that can only be read within a [fenced frame](https://github.com/shivanigithub/fenced-frame); the embedder does not learn this information. The chosen URL represents up to log2(num urls) bits of cross-site information. The URL must also be k-anonymous, in order to prevent much 1p data from also entering the Fenced Frame. Once the Fenced Frame receives a user gesture and navigates to its destination page, the information within the fenced frame leaks to the destination page. To limit the rate of leakage of this data, there is a bit budget applied to the output gate. If the budget is exceeded, the selectURL() will return the default (0th index) URL.

selectURL() is disallowed in Fenced Frame. This is to prevent leaking lots of bits all at once via selectURL() chaining (i.e. a fenced frame can call selectURL() to add a few more bits to the fenced frame's current URL and render the result in a nested fenced frame).

#### Budget Details
The rate of leakage of cross-site data need to be constrained. Therefore, we propose that there be a daily budget on how many bits of cross-site data can be leaked by the API. Note that each time a Fenced Frame is clicked on and navigates the top frame, up to log2(|urls|) bits can potentially be leaked. Therefore, Shared Storage will deduct that log2(|urls|) bits from the Shared Storage worklet's origin at that point. If the sum of the deductions from the last 24 hours exceed a threshold, then further selectURL()s will return the default value until some budget is freed up.

#### K-anonymity Details
Like [FLEDGE](https://github.com/WICG/turtledove/blob/main/FLEDGE.md), there will be a k-anonymity service to ensure that the selected URL has met its k-anonymity threshold. If it has not, its count will be increased by 1 on the k-anonymity server, but the default URL will be returned. This makes it possible to bootstrap new URLs.


### Private aggregation

Arbitrary cross-site data can be embedded into any aggregatable report, but that data is only readable via the aggregation service. Private aggregation protects the data as long as the number of reports aggregated is low enough. So, we must limit how many reports can be sent and to which URLs they may be sent (to prevent link decoration). The details of these limits are explored in the API's [explainer](https://github.com/alexmturner/private-aggregation-api#privacy-and-security).


### Choice of output type

The output type when running an operation must be pre-specified to prevent data leakage through the choice. This is enforced with separate functions for each output type, i.e. `sharedStorage.selectURL()` and `sharedStorage.run()`.


### <a name = "default"></a>Default values

When `sharedStorage.selectURL()` doesn’t return a valid output (including throwing an error), the user agent returns the first default URL, to prevent information leakage. For `sharedStorage.run()`, there is no output, so any return value is ignored.


### Preventing timing attacks

Revealing the time an operation takes to run could also leak information. We avoid this by having `sharedStorage.run()` queue the operation and then immediately resolve the returned promise. For `sharedStorage.selectURL()`, the promise resolves into an [opaque URL](https://github.com/shivanigithub/fenced-frame/blob/master/OpaqueSrc.md) that is mapped to the selected URL once the operation completes. Similarly, outside a worklet, `set()`, `remove()`, etc. return promises that resolve after queueing the writes. Inside a worklet, these writes join the same queue but their promises only resolve after completion.


## Possibilities for extension


### Allowing noised data as output to the embedder
We could consider allowing the worklet to send data directly to the embedder, with some local differential privacy guarantees. These might look similar to the differential privacy protections that we apply in the Private Aggregation API. 

### Interactions between worklets

Communication between worklets is not possible in the initial design. However, adding support for this would enable multiple origins to flexibly share information without needing a dedicated origin for that sharing. Relatedly, allowing a worklet to create other worklets might be useful.


### Registering event handlers

We could support event handlers in future iterations. For example, a handler could run a previously registered operation when a given key is modified (e.g. when an entry is updated via a set or append call):


```js
sharedStorage.addEventListener(
  "key" /* event_type */,
  "operation-to-run" /* operation_name */,
  {key: "example-key", actions: {"set", "append"}} /* options */);
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
