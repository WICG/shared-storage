# Shared Storage API Explainer

Authors: Alex Turner, Camillia Smith Barnes, Josh Karlin


## Introduction

In order to prevent cross-site user tracking, browsers are [partitioning](https://blog.chromium.org/2020/01/building-more-private-web-path-towards.html) all forms of storage (cookies, localStorage, caches, etc). But, there are many legitimate use cases currently relying on unpartitioned storage that will vanish without the help of new web APIs. We’ve seen a number of APIs proposed to fill in these gaps (e.g., [Conversion Measurement API](https://github.com/WICG/conversion-measurement-api), [Private Click Measurement](https://github.com/privacycg/private-click-measurement), [Storage Access](https://developer.mozilla.org/en-US/docs/Web/API/Storage_Access_API), [Trust Tokens](https://github.com/WICG/trust-token-api), [TURTLEDOVE](https://github.com/WICG/turtledove), [FLoC](https://github.com/WICG/floc)) and some remain (including cross-origin A/B experiments and user measurement). We propose a general-purpose, low-level API that can serve a number of these use cases.

The idea is to provide a storage API (named Shared Storage) that is intended to be unpartitioned. Origins can write to it from their own contexts on any page. To prevent cross-site tracking of users,  data in Shared Storage may only be read in a secure environment that has carefully constructed output gates. Over time, we hope to design and add additional gates.


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
var opaqueURL = await window.sharedStorage.runURLSelectionOperation(
  "select-url-for-experiment",
  ["blob:https://a.example/123…",
   "blob:https://b.example/abc…",
   "blob:https://c.example/789…"],
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
registerURLSelectionOperation("select-url-for-experiment", SelectURLOperation);
```


While the worklet script outputs the chosen index for `urls`, note that the browser process converts the index into a non-deterministic [opaque URL](https://github.com/shivanigithub/fenced-frame/blob/master/OpaqueSrc.md), which can only be read or rendered in a [fenced frame](https://github.com/shivanigithub/fenced-frame). Because of this, the `a.example` iframe cannot itself work out which ad was chosen. Yet, it is still able to customize the ad it rendered based on this protected information.


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
*   `window.sharedStorage.runOperation(name, options)`,  \
`window.sharedStorage.runURLSelectionOperation(name, urls, options)`, …
    *   Runs the operation previously registered by `registerXOperation()` with matching `name` and `X` (i.e. type). Does nothing if there’s no matching operation.
    *   Each operation returns a promise that resolves when the operation is queued:
        *   `runOperation()` returns a promise that resolves into `undefined`.
        *   `runURLSelectionOperation()` returns a promise that resolves into an [opaque URL](https://github.com/shivanigithub/fenced-frame/blob/master/OpaqueSrc.md) for the URL selected from `urls`. 
        *   `urls` is a list of URLs, with a max length of 8.
                *    The first value in the list is the `default URL`. This is selected if there is not enough budget remaining, or if the selected URL is not yet k-anonymous.
                *    The selected URL will be checked to see if it is k-anonymous. If it is not, its k-anonymity will be incremented, but the `default URL` will be returned.
        *    There will be a per-origin (the origin of the Shared Storage worklet) budget for `runURLSelectionOperation`. This is to limit the rate of leakage of cross-site data learned from the runURLSelectionOperation to the destination pages that the resulting Fenced Frames navigate to. Each time a Fenced Frame built with an opaque URL output from a runURLSelectionOperation navigates the top frame, log(|`urls`|) bits will be deducted from the budget. At any point in time, the current budget remaining will be calculated as `max_budget - sum(deductions_from_last_24hr)` 
    *   Options can include `data`, an arbitrary serializable object passed to the worklet.


### In the worklet, during `addModule()`



*   `registerOperation(name, operation)`,  \
`registerURLSelectionOperation(name, operation)`, …
    *   Registers a shared storage worklet operation with the provided `name`.
    *   `operation` should be a class with an async `run()` method.
        *   For `registerOperation()`, `run()` should take `data` as an argument and return nothing. Any return value is [ignored](#default).
        *   For `registerURLSelectionOperation()`, `run()` should take `data` and `urls` as arguments and return the index of the selected URL. Any invalid return value is replaced with a [default return value](#default).


### In the worklet, during an operation



*   `sharedStorage.get(key)`
    *   Returns a promise that resolves into the `key`‘s entry or an empty string if the `key` is not present.
*   `sharedStorage.key(n)` and `sharedStorage.length()`
    *   Returns a promise that resolves into the `n`th key or the number of keys, respectively.
*   `sharedStorage.set(key, value, options)`, `sharedStorage.append(key, value)`, `sharedStorage.delete(key)`, and `sharedStorage.clear()`
    *   Same as outside the worklet, except that the promise returned only resolves into `undefined` when the operation has completed.
*   A function to construct and then send an aggregatable report for the private, secure [aggregation service](https://github.com/WICG/conversion-measurement-api/blob/main/SERVICE.md), e.g. `createAndSendAggregatableReport()`
    *   The report contents (e.g. key, value) are encrypted and sent after a delay. The report can only be read by the service and processed into aggregate statistics.
    *   This functionality, including any limits imposed by the user agent, is somewhat speculative and will be detailed in a separate Aggregate Reporting API explainer.
*   Unrestricted access to identifying operations that would normally use up part of a page’s [privacy budget](http://github.com/bslassey/privacy-budget), e.g. `navigator.userAgentData.getHighEntropyValues()`


## Example scenarios

The following describe example use cases for Shared Storage and we welcome feedback on additional use cases that Shared Storage may help address.


### Cross-site reach measurement

Measuring the number of users that have seen an ad from a given campaign.


In the ad’s iframe:


```js
function generateSeed() { … }
window.sharedStorage.set("id", generateSeed(), {ignoreIfPresent: true});
await window.sharedStorage.worklet.addModule("reach.js");
await window.sharedStorage.runOperation("send-reach-report", {
  // optional one-time context
  data: {"campaign-id": "123", "favorite-color": "blue"}});
```


Worklet script (i.e. `reach.js`):


```js
class SendReachReportOperation {
  async function run(data) {
    // A toy model that only computes reach for users whose favorite color is red.
    if (data["favorite-color"] != "red") {
      return;  // Don't send a report.
    }

    // The user agent will send the report to a default endpoint after a delay.
    this.createAndSendAggregatableReport({
      operation: "count-distinct",  // i.e. count the number of unique values
      key: "campaign-id=" + data["campaign-id"],
      value: (await this.sharedStorage.get("id"))});
  }
}
registerOperation("send-reach-report", SendReachReportOperation);
```



### _K_+ frequency measurement

By instead maintaining a counter in shared storage, the approach for cross-site reach measurement could be extended to _K_+ frequency measurement, i.e. measuring the number of users who have seen _K_ or more ads on a given browser, for a pre-chosen value of _K_. A unary counter can be maintained by calling `window.sharedStorage.append("freq", "1")` on each ad view. Then, the `send-reach-report` operation would only send a report if there are more than _K_ characters stored at the key `"freq"`. This counter could also be used to filter out ads that have been shown too frequently (similarly to the A/B example above).


## Keep-alive worklet

After a document dies, the corresponding worklet will be kept alive for maximum two seconds to allow the pending operations to execute. This gives more confidence that the end-of-page operations (e.g. reporting) are able to finish.

## Dependencies

This API is dependent on the following other proposals:



*   [Fenced frames](https://github.com/shivanigithub/fenced-frame/) (and the associated concept of [opaque URLs](https://github.com/shivanigithub/fenced-frame/blob/master/OpaqueSrc.md)) to render the chosenURL without leaking the choice to the top-level document.
*   Aggregate reporting API to send reports for the private, secure [aggregation service](https://github.com/WICG/conversion-measurement-api/blob/main/SERVICE.md). Details and limitations are speculative and will be explored in a separate explainer.


## Output gates and privacy

The privacy properties of shared storage are enforced through limited output. So we must protect against any unintentional output channels, as well as against abuse of the intentional output channels.


### URL selection

The worklet selects from a small list of URLs. The chosen URL is stored in an opaque URL that can only be read within a [fenced frame](https://github.com/shivanigithub/fenced-frame); the embedder does not learn this information. However, a leak of up to log(_n_) bits (where _n_ is the size of the list) is possible when the fenced frame is clicked, as a navigation that embeds the selected URL may occur. Therefore a budget will be enforced to limit the rate of this leakage. See the API description for more detail.


### Aggregate reporting

Arbitrary cross-site data can be embedded into any report, but that data is only readable via the aggregation service. Private aggregation protects the data as long as the number of reports aggregated is low enough. So, we must limit how many reports can be sent and to which URLs they may be sent (to prevent link decoration). The details of these limits are speculative and will be described in a separate Aggregate Reporting API explainer.


### Choice of output type

The output type when running an operation must be pre-specified to prevent data leakage through the choice. This is enforced with separate functions for each output type, i.e. varying `X` in `run`/`registerXOperation()`.


### <a name = "default"></a>Default values

When a URL selection operation doesn’t return a valid output (including throwing an error), the user agent returns a default value, e.g. an [opaque URL](https://github.com/shivanigithub/fenced-frame/blob/master/OpaqueSrc.md) to “about:blank”, to prevent information leakage. For operations registered by `registerOperation()`, however, there is no output, so any return value is ignored.


### Preventing timing attacks

Revealing the time an operation takes to run could also leak information. We avoid this by having `runXOperation()` queue the operation and then immediately resolve the returned promise. For URL selection operations, the promise resolves into an [opaque URL](https://github.com/shivanigithub/fenced-frame/blob/master/OpaqueSrc.md) that is mapped to the selected URL once the operation completes. Similarly, outside a worklet, `set()`, `remove()`, etc. return promises that resolve after queueing the writes. Inside a worklet, these writes join the same queue but their promises only resolve after completion.


## Possibilities for extension


### Allowing noised data as output to the embedder
We could consider allowing the worklet to send data directly to the embedder, with some local differential privacy guarantees. These might look similar to the differential privacy protections that we apply to aggregate reporting. 

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
Mike West,
Yao Xiao.
