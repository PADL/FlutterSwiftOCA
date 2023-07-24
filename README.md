FlutterSwiftOCA
===============

This package allows the building of AES70/OCA client applications in Flutter, presenting a bridge between [FlutterSwift](https://github.com/PADL/FlutterSwift) and [SwiftOCA](https://github.com/PADL/SwiftOCA). OCP1 values are re-encoded using the chosen Flutter codec.

Channel prefix
--------------

All channel names are prefixed with the connection type and address, for example `oca/tcp/localhost:65000/`.

Control channel
---------------

Channel suffix is `control`. Argument is an `OcaObjectIdentification`, returning an optional `Bool`.

Methods:

* `connect`: argument ignored, connects to device
* `disconnect`: argument ignored, disconnects from device
* `resolve`: resolves the object identified by the argument and registers a method channel for it
* `registerMethodChannel`: registers method channel for an already resolved object
* `deregisterMethodChannel`: deregisters method channel

Event channel
-------------

Channel suffix is `event`. The object number is presented as an argument to the event channel's `onListen` method.

Events are emitted as `OcaPropertyChangedEventData` with the type `.currentChanged` (for now). Note however that unlike OCA events, all values are emitted, i.e. the minima and maxima for bounded properties. All properties are observed, they can be disambiguated by checking the `propertyID` field.

Method channel
--------------

Channel suffix is `method`. Arguments are `Ocp1Parameters` which are passed directly to the device, returning a `Ocp1Response`.

