# Shared Storage API Explainer

Authors: Alex Turner, Camillia Smith Barnes, Josh Karlin, Yao Xiao


## Introduction 

In order to prevent cross-site user tracking, browsers are [partitioning](https://blog.chromium.org/2020/01/building-more-private-web-path-towards.html) all forms of storage (cookies, localStorage, caches, etc) by top-frame site. But, there are many legitimate use cases currently relying on unpartitioned storage that will vanish without the help of new web APIs. We’ve seen a number of APIs proposed to fill in these gaps (e.g., [Conversion Measurement API](https://github.com/WICG/conversion-measurement-api), [Private Click Measurement](https://github.com/privacycg/private-click-measurement), [Storage Access](https://developer.mozilla.org/en-US/docs/Web/API/Storage_Access_API), [Private State Tokens](https://github.com/WICG/trust-token-api), [TURTLEDOVE](https://github.com/WICG/turtledove), [FLoC](https://github.com/WICG/floc)) and some remain (including cross-origin A/B experiments and user measurement). We propose a general-purpose storage API that can help to serve as common infrastructure for privacy preserving cross-site use cases.

Shared Storage is a key/value store that is partitioned by calling origin (but not top-frame site). The keys and values are strings. While it's possible to write to Shared Storage from nearly anywhere (including response headers!), it is only possible to read from Shared Storage in tightly controlled environments, such as a JavaScript worklet environment which is provided by Shared Storage. These worklets have no capability of communicating with the outside world. They have no network communication and no `postMessage`. The only way data can leave these worklets, is via privacy-preserving APIs.

### Specification

See the [draft specification](https://wicg.github.io/shared-storage/).

## APIs built on top of Shared Storage

This document only describes the core shared storage framework and infrastructure to store cross-site data privately and to read that data from within a secure worklet environment. APIs that use shared storage's data to produce some output are linked to below.

### Private Aggregation

The [Private Aggregation](https://github.com/patcg-individual-drafts/private-aggregation-api) API allows for aggregated histograms to be sent based on data read from shared storage. The histograms are differentially private.


### Select URL

The [selectURL](https://github.com/WICG/shared-storage/blob/main/select-url.md) API allows for content selection based on cross-site data. It takes 8 possible URLs as input and sends them to a worklet which selects from a small list of URLs. The chosen URL is stored in a fenced frame config as an opaque form that can only be read by a [fenced frame](https://github.com/WICG/fenced-frame); the embedder does not learn this information.


## Demonstration

You can [try out](https://shared-storage-demo.web.app/) Shared Storage along with some APIs built for it using Chrome 104+.


### Example 1: Writing an experiment id to Shared Storage from a document

Since Shared Storage is meant for writing from anywhere, but reading is tightly constrained, it's not actually possible to know what you might have written to your storage from other sites. Is this the first time you've seen this user? Who knows! As such, `Shared Storage` provides some useful functions beyond just `set` to write to keys only if they're not already present, and to append to a value rather than overwrite it.

For example, let's say that you wanted to add a user to an experiment group, with a random assignment. But you want that group assignment to be sticky for the user across all of the sites that they visit that your third-party script is on. You may not know if you've ever written this key from this site before, but you certainly don't know if you've set it from another site. To solve this issue, utilize the  `ignoreIfPresent` option.

```js
try {
    sharedStorage.set('group', Math.floor(Math.random() * 1000), { ignoreIfPresent: true });
} catch (error) {
    // Error handling
}
```
And `Shared Storage` will only write the value if the key is not already present.

### Example 2: Writing to Shared Storage via a worklet

In the event that `ignoreIfPresent` is not sufficient, and you need to read your existing `Shared Storage` data before adding new data, consider passing the information that you want to record to a worklet, and letting the worklet read the existing data and perform the write. Like so:

```js
try {
    const worklet = sharedStorage.createWorklet('https://site.example/writerWorklet.js');
    worklet.run('write', {data: {group: Math.floor(Math.random() * 1000)}});
} catch (error) {
    // Error handling
}
```

And your `writerWorklet.js` script would look like this:
`writerWorklet.js`
```js
class Writer {
  async run(data) {
    const existingGroup = sharedStorage.get('group');
    if (!existingGroup) {
        cibst newGroup = data['group'];
        sharedStorage.set('group', newGroup);
    }
  }
}
register('write', Writer);
```

### Example 3: Writing to Shared Storage with response headers
It may be faster and more convenient to write to Shared Storage directly from response headers than from JavaScript. This is encouraged in cases where data is coming from a server anyway as it's faster and less intensive than JavaScript methods if you're writing to an origin other than the current document's origin.

Response headers can be used on document, image, and fetch requests.

e.g.,:
```html
<iframe src="https://site.example/iframe" sharedstoragewritable></iframe>
```

The document request for "https://site.example/iframe" will include a `Sec-Shared-Storage-Writable: ?1` request header. Any request with this header can have a corresponding `Shared-Storage-Write` response header that can write, like so:
```js
Shared-Storage-Write: set;key="group";value="4";ignore_if_present
```

### Example 4: Counting the number of views your content has received across sites
To count the number of times the user has viewed your third-party content, consider using the append option. Like so:

e.g.,:
```js
try {
    window.sharedStorage.append('count', '1');
} catch (error) {
    // Error handling
}
```

Then, sometime later in your worklet, you can get the total count:
```js
class Counter {
  async run(data) {
    const countLog = data['count']; // e.g.,: '111111111'
    const count = countLog.length;
    // do something useful with this data (such as recording an aggregate histogram) here...
  }
}
register('count', Counter);
```

## Goals

This API intends to support the storage and access needs for a wide array of cross-site data use cases. This prevents each API from having to create its own bespoke storage APIs.


## Related work

There have been multiple privacy proposals ([SPURFOWL](https://github.com/AdRoll/privacy/blob/main/SPURFOWL.md), [SWAN](https://github.com/1plusX/swan), [Aggregated Reporting](https://github.com/csharrison/aggregate-reporting-api)) that have a notion of write-only storage with limited output. Shared Storage allows for each of those use cases, with only one storage API which is easier for developers to learn and requires less browser code. We’d also like to acknowledge the [KV Storage](https://github.com/WICG/kv-storage) explainer, to which we turned for API-shape inspiration.


## Proposed API surface


### Outside of worklets (e.g., places where writing can happen)
The setter methods (`set`, `append`, `delete`, and `clear`) should be made generally available across most any context. That includes top-level documents, iframes, shared storage worklets,  Protected Audience worklets, service workers, dedicated workers, etc.

The shared storage worklet invocation methods (`addModule`, `createWorklet`, and `run`) are available within document contexts.


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
*   `window.sharedStorage.worklet.run(name, options)`
    *   Runs the operation previously registered by `register()` with matching `name`. Does nothing if there’s no matching operation.
    *   Returns a promise that resolves to `undefined` when the operation is queued:
    *   Options can include:
        *   `data`, an arbitrary serializable object passed to the worklet.
        *   `keepAlive` (defaults to false), a boolean denoting whether the worklet should be retained after it completes work for this call.
            *   If `keepAlive` is false or not specified, the worklet will shutdown as soon as the operation finishes and subsequent calls to it will fail.
            *   To keep the worklet alive throughout multiple calls to `run()`, each of those calls must include `keepAlive: true` in the `options` dictionary.
*   `window.sharedStorage.run(name, options)`
    *   The behavior is identical to `window.sharedStorage.worklet.run(name, options)`.
*   `window.sharedStorage.createWorklet(url, options)`
    *   Creates a new worklet, and loads and adds the module to the worklet (similar to the handling for `window.sharedStorage.worklet.addModule(url, options)`).
    *   By default, the worklet uses the invoking context's origin as its partition origin for accessing shared storage data and for budget checking and withdrawing.
        *   To instead use the worklet script origin (i.e. `url`'s origin) as the partition origin for accessing shared storage, pass the `dataOrigin` option with "script-origin" as its value in the `options` dictionary.
        *   Currently, the `dataOrigin` option, if used, is restricted to having either "script-origin" or "context-origin" as its value. "script-origin" designates the worklet script origin as the data partition origin; "context-origin" designates the invoking context origin as the data partition origin.
    *   The object that the returned Promise resolves to has the same type with the implicitly constructed `window.sharedStorage.worklet`. However, for a worklet created via `window.sharedStorage.createWorklet(url, options)`, only the invocation methods (e.g., `run`)  are available, whereas calling `addModule()` will throw an error. This is to prevent leaking shared storage data via `addModule()`, similar to the reason why `addModule()` can only be invoked once on the implicitly constructed `window.sharedStorage.worklet`.
    *   Redirects are not allowed.
    *   When the module script's URL's origin is cross-origin with the worklet's creator window's origin and when `dataOrigin` is "script-origin", a `Shared-Storage-Cross-Origin-Worklet-Allowed: ?1` response header is required.
    *   The script server must carefully consider the security risks of allowing worklet creation by other origins (via `Shared-Storage-Cross-Origin-Worklet-Allowed: ?1` and CORS), because this will also allow the worklet creator to run subsequent operations, and a malicious actor could poison and use up the worklet origin's budget.



### In the worklet, during `sharedStorage.worklet.addModule(url, options)` or `sharedStorage.createWorklet(url, options)`
*   `register(name, operation)`
    *   Registers a shared storage worklet operation with the provided `name`.
    *   `operation` should be a class with an async `run()` method.
        *   For the operation to work with `sharedStorage.run()`, `run()` should take `data` as an argument and return nothing. Any return value is [ignored](#default).


### In the worklet, during an operation
*   `sharedStorage.get(key)`
    *   Returns a promise that resolves into the `key`‘s entry or an empty string if the `key` is not present.
*   `sharedStorage.length()`
    *   Returns a promise that resolves into the number of keys.
*   `sharedStorage.keys()` and `sharedStorage.entries()`
    *   Returns an async iterator for all the stored keys or [key, value] pairs, sorted in the underlying key order.
*   `sharedStorage.set(key, value, options)`, `sharedStorage.append(key, value)`, `sharedStorage.delete(key)`, and `sharedStorage.clear()`
    *   Same as outside the worklet, except that the promise returned only resolves into `undefined` when the operation has completed.
*  `sharedStorage.context`
    *   From inside a worklet created inside a [fenced frame](https://github.com/wicg/fenced-frame/), returns a string of contextual information, if any, that the embedder had written to the [fenced frame](https://github.com/wicg/fenced-frame/)'s [FencedFrameConfig](https://github.com/WICG/fenced-frame/blob/master/explainer/fenced_frame_config.md) before the [fenced frame](https://github.com/wicg/fenced-frame/)'s navigation.
    *   If no contextual information string had been written for the given frame, returns undefined.
*   `interestGroups()`
    *   Returns a promise that resolves into an array of `StorageInterestGroup`. A `StorageInterestGroup` is a dictionary that extends the [AuctionAdInterestGroup](https://wicg.github.io/turtledove/#dictdef-auctionadinterestgroup) dictionary with the following attributes:
        *   unsigned long long `joinCount`
        *   unsigned long long `bidCount`
        *   sequence<[PreviousWin](https://wicg.github.io/turtledove/#typedefdef-previouswin)> `prevWinsMs`
        *   USVString `joiningOrigin`
        *   double `timeSinceGroupJoinedMs`
        *   double `lifetimeRemainingMs`
        *   double `timeSinceLastUpdateMs`
        *   double `timeUntilNextUpdateMs`
        *   unsigned long long `estimatedSize`
            *   The approximate size of the contents of this interest group, in bytes.
    *   The [AuctionAdInterestGroup](https://wicg.github.io/turtledove/#dictdef-auctionadinterestgroup)'s [lifetimeMs](https://wicg.github.io/turtledove/#dom-auctionadinterestgroup-lifetimems) field will remain unset. It's no longer applicable at query time and is replaced with attributes `timeSinceGroupJoinedMs` and `lifetimeRemainingMs`.
    *   This API provides the Protected Audience buyer with a better picture of what's happening with their users, allowing for Private Aggregation reports.
*   Functions exposed by APIs built on top of Shared Storage such as the [Private Aggregation API](https://github.com/alexmturner/private-aggregation-api), e.g. `privateAggregation.contributeToHistogram()`.
    *   These functions construct and then send an aggregatable report for the private, secure [aggregation service](https://github.com/WICG/conversion-measurement-api/blob/main/AGGREGATION_SERVICE_TEE.md).
    *   The report contents (e.g. key, value) are encrypted and sent after a delay. The report can only be read by the service and processed into aggregate statistics.
    *   After a Shared Storage operation has been running for 5 seconds, Private Aggregation contributions are timed out. Any future contributions are ignored and contributions already made are sent in a report as if the Shared Storage operation had completed.


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
try {
    await window.sharedStorage.worklet.addModule('report.js');
    await window.sharedStorage.run('send-report', {
    data: { info: frameInfo },
    });
} catch (error) {
    // Error handling
}
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

### Loading cross-origin worklet scripts

There are currently four (4) approaches to creating a worklet that loads cross-origin script. The partition origin for the worklet's shared storage data access depends on the approach.

#### Using the context origin as data partition origin
The first three (3) approaches use the invoking context's origin as the partition origin for shared storage data access and the invoking context's site for shared storage budget withdrawals.

1. Call `addModule()` with a cross-origin script.

    In an "https://a.example" context in the embedder page:

    ```
    await sharedStorage.worklet.addModule("https://b.example/worklet.js");
    ```

    For any subsequent `run()` or `selectURL()` operation invoked on this worklet, the shared storage data for "https://a.example" (i.e. the context origin) will be used.

2. Call `createWorklet()` with a cross-origin script.

    In an "https://a.example" context in the embedder page:

    ```
    const worklet = await sharedStorage.createWorklet("https://b.example/worklet.js");
    ```

    For any subsequent `run()` or `selectURL()` operation invoked on this worklet, the shared storage data for "https://a.example" (i.e. the context origin) will be used.

3. Call `createWorklet()` with a cross-origin script, setting its `dataOption` to the invoking context's origin.

    In an "https://a.example" context in the embedder page:

    ```
    const worklet = await sharedStorage.createWorklet("https://b.example/worklet.js", {dataOrigin: "context-origin"});
    ```

    For any subsequent `run()` or `selectURL()` operation invoked on this worklet, the shared storage data for "https://a.example" (i.e. the context origin) will be used.

#### Using the worklet script origin as data partition origin
The fourth approach uses the worklet script's origin as the partition origin for shared storage data access and the worklet script's site for shared storage budget withdrawals.

4. Call `createWorklet()` with a cross-origin script, setting its `dataOption` to the worklet script's origin.

    In an "https://a.example" context in the embedder page:

    ```
    const worklet = await sharedStorage.createWorklet("https://b.example/worklet.js", {dataOrigin: "script-origin"});
    ```

    For any subsequent `run()` or `selectURL()` operation invoked on this worklet, the shared storage data for "https://b.example" (i.e. the worklet script origin) will be used.


## Error handling
Note that the shared storage APIs may throw for several possible reasons. The following list of situations is not exhaustive, but, for example, the APIs may throw if the site invoking the API is not [enrolled](https://github.com/privacysandbox/attestation/blob/main/how-to-enroll.md) and/or [attested](https://github.com/privacysandbox/attestation/blob/main/README.md#core-privacy-attestations), if the user has disabled shared storage in site settings, if the "shared-storage" or "shared-storage-select-url" permissions policy denies access, or if one of its arguments is invalid.

We recommend handling exceptions. This can be done by wrapping `async..await` calls to shared storage JS methods in `try...catch` blocks, or by following calls that are not awaited with `.catch`:

  ```js
  try {
    await window.sharedStorage.worklet.addModule('worklet.js');
  } catch (error) {
    // Handle error.
  }
  ```

  ```js
  window.sharedStorage.worklet.addModule('worklet.js')
    .catch((error) => {
    // Handle error.
  });
  ```
## Worklets can outlive the associated document

After a document dies, the corresponding worklet (if running an operation) will continue to be kept alive for a maximum of two seconds to allow the pending operation(s) to execute. This gives more confidence that any end-of-page operations (e.g. reporting) are able to finish.

## Permissions Policy

Shared storage methods can be disallowed by the "shared-storage" [policy-controlled feature](https://w3c.github.io/webappsec-permissions-policy/#policy-controlled-feature). Its default allowlist is * (i.e. every origin). APIs built on top of Shared Storage have their own specific permission policies, so it is possible to allow reading and writing of Shared Storage while disabling particular APIs.

### Permissions Policy inside the shared storage worklet
The permissions policy inside the shared storage worklet will inherit the permissions policy of the associated document.

## Data Retention Policy
Each key is cleared after thirty days of last write (`set` or `append` call). If `ignoreIfPresent` is true, the last write time is updated.

## Data Storage Limits
Shared Storage is not subject to the quota manager, as that would leak information across sites. Therefore we limit the per-origin total key and value bytes to 5MB.


## Privacy

Shared Storage prevents privacy side-channel leaks when writing data and creating worklets by immediately returning and not exposing the time it takes for the underlying operation to run. The APIs that can read data from Shared Storage have their own privacy documentation.

#### Enrollment and Attestation
Use of Shared Storage requires [enrollment](https://github.com/privacysandbox/attestation/blob/main/how-to-enroll.md) and [attestation](https://github.com/privacysandbox/attestation/blob/main/README.md#core-privacy-attestations) via the [Privacy Sandbox enrollment attestation model](https://github.com/privacysandbox/attestation/blob/main/README.md).

For each method in the Shared Storage API surface, a check will be performed to determine whether the calling [site](https://html.spec.whatwg.org/multipage/browsers.html#site) is [enrolled](https://github.com/privacysandbox/attestation/blob/main/how-to-enroll.md) and [attested](https://github.com/privacysandbox/attestation/blob/main/README.md#core-privacy-attestations). In the case where the [site](https://html.spec.whatwg.org/multipage/browsers.html#site) is not [enrolled](https://github.com/privacysandbox/attestation/blob/main/how-to-enroll.md) and [attested](https://github.com/privacysandbox/attestation/blob/main/README.md#core-privacy-attestations), the promise returned by the method is rejected.


## Possibilities for extension

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
