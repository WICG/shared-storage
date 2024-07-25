# selectURL API Explainer

For browser users that have third-party cookies disabled, third parties on the page might still want to select content to show those users based on cross-site data in a privacy-positive way.  For instance, they may want to a/b test their third-party embed consistently for a user across sites. Or, they may want to show a different login button for users that are known to have an account vs those that don’t. 

The `selectURL` API is designed for such use cases. It allows the caller to choose between a set of URLs based on third-party data. The API is built on top of [shared storage](https://github.com/WICG/shared-storage) and uses a shared storage worklet to read the available cross-site data and select one of the given URLs. The selected URL is returned to the caller in an opaque fashion, such that it can’t be read except within a [fenced frame](https://github.com/WICG/fenced-frame/tree/master/explainer). 

This means that the selected URL needs to be fenced frame compatible, and not communicate with the page it’s embedded on, save for say a click notification.



## Simple example: Consistent A/B experiments across sites

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

## Demonstration 

You can [try it out](https://shared-storage-demo.web.app/) using Chrome 104+ (currently in canary and dev channels as of June 7th 2022).



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

`window.sharedStorage.worklet.selectURL(name, urls, options)`

* The `name` and `options` parameters are identical to those found in `window.sharedStorage.worklet.run`. The difference is the urls input parameter which lists the URLs to select from, and the fact that the worklet operation must choose one of them by returning an integer index.
* `urls` is a list of dictionaries, each containing a candidate URL `url` and optional reporting metadata (a dictionary, with the key being the event type and the value being the reporting URL; identical to Protected Audience's [registerAdBeacon()](https://github.com/WICG/turtledove/blob/main/Fenced_Frames_Ads_Reporting.md#registeradbeacon) parameter), with a max length of 8.
  
  * The `url` of the first dictionary in the list is the `default URL`. This is selected if there is a script error, or if there is not enough budget remaining.

  * The reporting metadata will be used in the short-term to allow event-level reporting via `window.fence.reportEvent()` as described in the [Protected Audience explainer](https://github.com/WICG/turtledove/blob/main/Fenced_Frames_Ads_Reporting.md).

*    There will be a per-[site](https://html.spec.whatwg.org/multipage/browsers.html#site) (the site of the Shared Storage worklet) budget for `selectURL`. This is to limit the rate of leakage of cross-site data learned from the selectURL to the destination pages that the resulting Fenced Frames navigate to. Each time a Fenced Frame navigates the top frame, for each `selectURL()` involved in the creation of the Fenced Frame, log(|`urls`|) bits will be deducted from the corresponding [site](https://html.spec.whatwg.org/multipage/browsers.html#site)’s budget. At any point in time, the current budget remaining will be calculated as `max_budget - sum(deductions_from_last_24hr)`

* The promise resolves to a fenced frame config only when `resolveToConfig` property is set to `true`. If the property is set to `false` or not set, the promise resolves to an opaque URN that can be rendered by an iframe.

* For the associated operation in the worklet to work with `sharedStorage.selectURL()`, `run()` should take `data` and `urls` as arguments and return the index of the selected URL. Any invalid return value is replaced with a [default return value](#default).


## A second example, ad creative selection by frequency

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


## Permissions Policy

The sharedStorage.selectURL() method can be disallowed by the "shared-storage-select-url" [policy-controlled feature](https://w3c.github.io/webappsec-permissions-policy/#policy-controlled-feature). Its default allowlist is * (i.e. every origin).


## Dependencies

This API is dependent on the following other proposals:



*   Shared Storage to read and write cross-site data in a private manner.
*   [Fenced frames](https://github.com/WICG/fenced-frame) (and the associated concept of [fenced frame configs](https://github.com/WICG/fenced-frame/blob/master/explainer/fenced_frame_config.md)) to render the chosen URL without leaking the choice to the top-level document.


## Privacy
The worklet selects from a small list of (up to 8) URLs, each in its own dictionary with optional reporting metadata. The chosen URL is stored in a fenced frame config as an opaque form that can only be read by a [fenced frame](https://github.com/WICG/fenced-frame); the embedder does not learn this information. The chosen URL represents up to log2(num urls) bits of cross-site information (as measured according to [information theory](https://en.wikipedia.org/wiki/Entropy_(information_theory))). Once the Fenced Frame receives a user gesture and navigates to its destination page, the information within the fenced frame leaks to the destination page. To limit the rate of leakage of this data, there is a bit budget applied to the output gate. If the budget is exceeded, the selectURL() will return the default (0th index) URL.

selectURL() can be called in a top-level fenced frame, but not from within a nested fenced frame. This is to prevent leaking lots of bits all at once via selectURL() chaining (i.e. a fenced frame can call selectURL() to add a few more bits to the fenced frame's current URL and render the result in a nested fenced frame). Use cases that will benefit from selectURL() being allowed from inside the top level fenced frame: [issue](https://github.com/WICG/fenced-frame/issues/44).

## Budgeting
The rate of leakage of cross-site data need to be constrained. Therefore, we propose that there be a daily budget on how many bits of cross-site data can be leaked by the API per [site](https://html.spec.whatwg.org/multipage/browsers.html#site). Note that each time a Fenced Frame is clicked on and navigates the top frame, up to log2(|urls|) [bits of information](https://en.wikipedia.org/wiki/Entropy_(information_theory)) can potentially be leaked for each selectURL() involved in the creation of the Fenced Frame. Therefore, Shared Storage will deduct that log2(|urls|) bits from the Shared Storage worklet's [site](https://html.spec.whatwg.org/multipage/browsers.html#site)'s budget at that point. If the sum of the deductions from the last 24 hours exceed a threshold, then further selectURL()s will return the default value (the first url in the list) until some budget is freed up.

Why do we assume that log2(|urls|) bits of cross-site information are leaked by a call to `selectURL`? Because the embedder (the [site](https://html.spec.whatwg.org/multipage/browsers.html#site) calling `selectURL`) is providing a list of urls to choose from using cross-site information. If `selectURL` were abused to leak the first few bits of the user's cross-site identity, then, with 8 URLs to choose from, they could leak the first 3 bits of the id (e.g., imagine urls: https://example.com/id/000, https://example.com/id/001, https://example.com/id/010, ..., https://example.com/id/111). One can leak at most log2(|urls|) bits, and so that is what we deduct from the budget, but only after the fenced frame navigates the top page which is when its data can be communicated.

#### Budget Details
The budgets for bits of entropy for selectURL are as follows.

##### Long Term Budget

In the long term, `selectURL()` will leak bits of entropy on top-level navigation (e.g., a tab navigates). Therefore it is necessary to impose a budget for this leakage.

* There is a 12 bit daily per-[site](https://html.spec.whatwg.org/multipage/browsers.html#site) budget for `selectURL()`, to be queried on each `selectURL()` call for sufficient budget and charged on navigation. This is subject to change.
* The cost of a `selectURL()` call is log2(number of urls to `selectURL()` call) bits. This cost is only logged once the fenced frame holding the selected URL navigates the top frame. e.g., if the fenced frame can't communicate its contents (doesn't navigate), then there is no budget cost for that call to`selectURL()`.
* The remaining budget at any given time for a [site](https://html.spec.whatwg.org/multipage/browsers.html#site) is 12 - (the sum of the log of budget deductions from the past 24 hours).
* If the remaining budget is less than log2(number of urls in `selectURL()` call), the default URL is returned and 1 bit is logged if the fenced frame is navigated.

##### Short Term Budgets

In the short term, we have event-level reporting and less-restrictive [fenced frames](https://github.com/WICG/fenced-frame), which allow further leakage; thus it is necessary to impose additional limits. On top of the navigation bit budget described above, there will be two more budgets, each maintained on a per top-level navigation basis. The bit values for each call to `selectURL()` are calculated in the same way as detailed for the navigation bit budget.

* Each page load will have a per-[site](https://html.spec.whatwg.org/multipage/browsers.html#site) bit budget of 6 bits for `selectURL()` calls. At the start of a new top-level navigation, this budget will refresh.
* Each page load will also have an overall bit budget of 12 bits for `selectURL()`. This budget will be contributed to by all sites on the page. As with the per-[site](https://html.spec.whatwg.org/multipage/browsers.html#site) per-page load bit budget, this budget will refresh when the top frame navigates.

## Enrollment and Attestation
Use of selectURL requires shared storage [enrollment](https://github.com/privacysandbox/attestation/blob/main/how-to-enroll.md) and [attestation](https://github.com/privacysandbox/attestation/blob/main/README.md#core-privacy-attestations) via the [Privacy Sandbox enrollment attestation model](https://github.com/privacysandbox/attestation/blob/main/README.md).

A check will be performed to determine whether the calling [site](https://html.spec.whatwg.org/multipage/browsers.html#site) is [enrolled](https://github.com/privacysandbox/attestation/blob/main/how-to-enroll.md) and [attested](https://github.com/privacysandbox/attestation/blob/main/README.md#core-privacy-attestations). In the case where the [site](https://html.spec.whatwg.org/multipage/browsers.html#site) is not [enrolled](https://github.com/privacysandbox/attestation/blob/main/how-to-enroll.md) and [attested](https://github.com/privacysandbox/attestation/blob/main/README.md#core-privacy-attestations), the promise returned by the method is rejected.


## Event Level Reporting
In the long term we'd like all reporting via selectURL to happen via the Private Aggregation output gate (or some additional noised reporting gate). We understand that in the short term it may be necessary for the industry to continue to use event-level reporting as they transition to more private reporting. Event-level reporting for content selection (`selectURL()`) will be available until at least 2026, and we will provide substantial notice for developers before the transition takes place.

Event level reports work in a way similar to how they work in Protected Audience. First, when calling selectURL, the caller adds a `reportingMetadata` optional dict to the URLs that they wish to send reports for, such as:
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

## <a name = "default"></a>Default values

When `sharedStorage.selectURL()` doesn’t return a valid output (including throwing an error), the user agent returns the first default URL, to prevent information leakage. For `sharedStorage.run()`, there is no output, so any return value is ignored.

## Preventing timing attacks

Revealing the time an operation takes to run could also leak information. We avoid this by having `sharedStorage.selectURL()` immediately return the promise which later resolves into an [fenced frame config](https://github.com/WICG/fenced-frame/blob/master/explainer/fenced_frame_config.md) that contains the opaque URL that is mapped to the selected URL once the operation completes. A Fenced Frame can be created with the returned fenced frame config even before the selectURL operation has completed. The frame will wait for it to complete first.  Similarly, outside a worklet, `set()`, `remove()`, etc. return promises that resolve after queueing the writes. Inside a worklet, these writes join the same queue but their promises only resolve after completion.

