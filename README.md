FlutterSwiftOCA
===============

This package allows the building of AES70/OCA client applications in Flutter, presenting a bridge between [FlutterSwift](https://github.com/PADL/FlutterSwift) and [SwiftOCA](https://github.com/PADL/SwiftOCA). OCP.1 values are re-encoded using the chosen Flutter codec.

The Swift side owns the OCP.1 connection: object resolution, property caching, event subscription and reconnection are all handled by SwiftOCA. Dart sees a set of platform channels that address OCA objects by object number and property/method ID, and receives property values already decoded into Flutter standard-codec types (`int`, `double`, `bool`, `String`, `Uint8List`, `List`, `Map`). Only the method channel deals in raw OCP.1 parameter bytes.

There is no Dart API or widget library in this package: you add it as a dependency of the Swift half of your Flutter application, and implement the Dart side against the channel protocol described below.

Requirements
------------

* Swift 6.0 or later (CI builds with 6.3)
* macOS 15+ or iOS 18+ on Apple platforms; Linux (via [flutter-elinux](https://github.com/sony/flutter-elinux)) and Android are also supported
* C++ interoperability enabled for the target, as FlutterSwift links against the Flutter engine's C API

Installation
------------

```swift
.package(url: "https://github.com/PADL/FlutterSwiftOCA", branch: "main"),
```

and add `FlutterSwiftOCA` to your target's dependencies. The target must be built with `.interoperabilityMode(.Cxx)` and, on Apple platforms, Swift 5 language mode, matching this package's own settings.

Usage
-----

Create an `OcaChannelManager` on the Flutter platform thread, passing it an `Ocp1Connection` and the engine's binary messenger:

```swift
let connection = try await Ocp1TCPConnection(deviceAddress: address, options: options)

let channelManager = try await FlutterPlatformThreadActor.run {
  try OcaChannelManager(
    connection: connection,
    binaryMessenger: engine.binaryMessenger,
    logger: logger
  )
}

try await channelManager.connect()
```

The initialiser registers every channel handler before returning, then tells Dart it is safe to bind to them (see [Platform state channel](#platform-state-channel) below). `connect()` opens the OCP.1 connection; `dispose()` unregisters the handlers and finishes any outstanding metering streams, and must also be called on the platform thread.

Initialiser parameters:

| Parameter | Description |
| --- | --- |
| `connection` | the SwiftOCA connection to bridge |
| `binaryMessenger` | the Flutter engine's binary messenger |
| `logger` | swift-log `Logger`; most per-message logging is at `trace` level |
| `flags` | see below |
| `propertyEventChannelBufferSize` | depth of the property event channel buffer (default 10) |
| `channelSuffix` | inserted into every channel name, to support more than one device per engine (default `nil`) |
| `identificationSensorONo` | object number of an `OcaIdentificationSensor`, if the device has one |

The only flag currently defined is `.persistSubscriptions`, which leaves OCA event subscriptions in place when the last Dart listener for an object cancels. This avoids churning subscriptions in UIs that repeatedly build and dispose widgets for the same object, at the cost of leaving the device emitting events nobody is listening to.

Channel naming
--------------

All channel names are prefixed with `oca/`, or with `oca/<channel-suffix>/` when a `channelSuffix` was supplied. A suffix is what allows a single Flutter engine to talk to several devices at once; `OcaBrokerChannelManager` uses the device identifier as the suffix.

In the definitions below, `<object-id>` is one of:

* `<dotted-class-id>@<class-version>:<hex-ono>`
* `<dotted-class-id>:<hex-ono>`
* `<hex-ono>`

For example, `1.1.3@3:80001000`, or `1.1.3:80001000` (will default to the AES70-2023 class version), or `80001000` (will query device over network to determine class, if not already resolved).

Object numbers are always hexadecimal with no leading `0x`. Method and property IDs are dotted decimal, e.g. `3.2`.

Channel summary
---------------

| Channel | Type | Purpose |
| --- | --- | --- |
| `oca/method` | method | invoke an arbitrary OCA method |
| `oca/get_property` | method | read a property |
| `oca/set_property` | method | write a property |
| `oca/sample_rate` | method | get/set an `OcaMediaClock3` nominal rate |
| `oca/dataset` | method | apply or store a block parameter dataset |
| `oca/dataset_blob` | method | fetch or apply block parameter data as a blob |
| `oca/platform_state` | method | Swift → Dart readiness notification |
| `oca/property_event` | event | property change events |
| `oca/metering_event` | event | high-rate metering events |
| `oca/connection_state` | event | OCP.1 connection state |
| `oca/identify` | event | device identification events |

Method channel
---------------

* Channel is `oca/method`
* Method syntax is `<object-id>/<dotted-method-id>` (with no leading 0x)
* Arguments are `List<Uint8List>` where each item is an encoded parameter to be passed to the OCA device
* Return value is the response parameter data as `Uint8List`. The response parameter count is not returned.
* A non-`ok` OCA status is reported as an error

This will mostly be useful for testing, unless you wish to build your own OCP.1 serializers in Dart.

Get property channel
--------------------

* Channel is `oca/get_property`
* Method syntax is `<object-id>/<dotted-property-id>`
* Arguments are null
* Return value is the property value, bridged to a Flutter standard-codec value

The value is read through SwiftOCA's property subject, so where a cached value is available it is returned without a network round trip.

Set property channel
--------------------

* Channel is `oca/set_property`
* Method syntax is `<object-id>/<dotted-property-id>`
* Arguments are the property value as a Flutter standard-codec value
* Return value is null

The argument is coerced to the property's declared Swift type before being sent; a value that cannot be represented in that type is reported as an error.

Sample rate channel
-------------------

* Channel is `oca/sample_rate`
* Method syntax is `<object-id>`, which must resolve to an `OcaMediaClock3`
* Arguments are the new nominal rate in Hz as a `double`, or null to read the current rate
* Return value is the nominal rate in Hz as a `double`

Dataset channel
---------------

* Channel is `oca/dataset`
* Method syntax is `<object-id>/apply` or `<object-id>/store`, where the object must resolve to an `OcaBlock`
* Arguments are the object number of the dataset object (an `int`) to apply from, or to store the block's current parameters into
* Return value is null

Dataset blob channel
--------------------

* Channel is `oca/dataset_blob`
* Method syntax is `<object-id>/fetch` or `<object-id>/apply`, where the object must resolve to an `OcaBlock`
* Arguments for `apply` are the parameter data as `Uint8List`; for `fetch` they are ignored
* Return value for `fetch` is the block's current parameter data as `Uint8List`; for `apply` it is empty

This is the same parameter data the dataset channel deals with, but carried in the message rather than stored in a dataset object on the device, so it can be persisted by the application.

Platform state channel
----------------------

* Channel is `oca/platform_state`
* Handled by *Dart*, not by Swift: the channel manager invokes it once initialisation is complete
* Method is `platform_ready`, with the argument `true`

Dart should set a method call handler on this channel before the channel manager is constructed, and defer binding to the other channels until `platform_ready` arrives. Subscribing earlier races handler registration.

Property event channel
----------------------

* Channel is `oca/property_event`
* Listener parameter is `<object-id>/<dotted-property-id>`
* Event data is the property value, bridged to a Flutter standard-codec value

Listening subscribes to the object's `PropertyChanged` event if this is the first listener for that object. Subscriptions are reference counted per object number, so several properties of one object cost one OCA subscription; the subscription is dropped when the last listener cancels, unless `.persistSubscriptions` is set.

The channel buffer is sized by `propertyEventChannelBufferSize` and allows overflow, so a slow Dart isolate drops old values rather than blocking the connection.

Metering event channel
----------------------

* Channel is `oca/metering_event`
* Listener parameter is `<object-id>/<dotted-property-id>`
* Event data is the meter reading as a `double`

This is a separate path from the property event channel for properties that update at metering rates. It subscribes to the object's `PropertyChanged` event directly and buffers only the newest value, so a UI that cannot keep up sees the most recent reading rather than a backlog.

The property value is assumed to be an `OcaDB`; a metering property of any other type will not decode.

Connection state channel
------------------------

* Channel is `oca/connection_state`
* Listener parameter is ignored
* Event data is `Ocp1ConnectionState` integer raw value

The raw values are `0` notConnected, `1` connecting, `2` connected, `3` reconnecting, `4` connectionTimedOut, `5` connectionFailed.

The stream carries transitions only, so bind to it before connecting — otherwise a connection that completes first is never reported.

Identify channel
----------------

* Channel is `oca/identify`
* Listener parameter is ignored
* Event data is `true`, once per identification event

Requires `identificationSensorONo` to have been passed to the channel manager; listening otherwise fails to resolve the sensor and the stream errors.

Error reporting
---------------

`Ocp1Error`s raised while handling a call are translated into a Flutter error whose code is the channel prefix followed by the Swift description of the error, for example `oca/status(badONo)`. The message and stack trace fields are unused. Errors that are not `Ocp1Error`s propagate as-is.

Connection broker
-----------------

`OcaBrokerChannelManager` adds device discovery, for applications that browse for devices rather than being pointed at a fixed address. It is available wherever SwiftOCA's `OcaConnectionBroker` is — Apple platforms, Linux with Avahi, and Android via `NsdManager`.

It browses the network, reports devices to Dart, and creates an `OcaChannelManager` per connected device, using the device identifier as that manager's channel suffix. Discovery can be restricted to particular service types, and to particular model GUIDs so that foreign devices on the network are never surfaced to Dart.

A device identifier is the string `<service-type>#<model-guid>#<serial-number>`, and is used both as the handle in the control channel and as the channel suffix for that device's own channels — so a device's method channel is `oca/<service-type>#<model-guid>#<serial-number>/method`.

### Broker event channel

* Channel is `oca-broker/events`
* Listener parameter is ignored
* Event data is a three-element list: `[<event-type>, <device-id>, <device-name>]`, where `<event-type>` is `added`, `removed` or `updated`

### Broker control channel

* Channel is `oca-broker/control`
* Return value is an empty list
* Methods:
  * `connect`, argument is the device identifier — registers the device's channels, then connects it. The channels are in place before the connection is made, so Dart can bind to them and observe the connection state transitions.
  * `disconnect`, argument is the device identifier — disposes the device's channels and disconnects it
  * `list`, argument ignored — re-emits an `added` event for every device already known to the broker, for a Dart side that bound to the event channel late

### Application lifecycle

`suspend()` disconnects every connected device and remembers them; `resume()` reconnects them. Channel registrations are deliberately left in place across the cycle so that Dart's bindings survive it, and event subscriptions are restored by the connection's own `refreshSubscriptionsOnReconnection`. Call these from your platform's background/foreground notifications on mobile, where the OS expects network resources to be released while the app is not in use.

Building
--------

```
swift build
swift test
```

On Linux the FlutterSwift backend is selected with the `FLUTTER_SWIFT_BACKEND` environment variable (CI builds with `wayland`), and the Wayland/DRM development packages listed in [.github/workflows/swift.yml](.github/workflows/swift.yml) are required.

License
-------

Apache License 2.0. See [LICENSE.md](LICENSE.md).
