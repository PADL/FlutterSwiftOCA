FlutterSwiftOCA
===============

This package allows the building of AES70/OCA client applications in Flutter, presenting a bridge between [FlutterSwift](https://github.com/PADL/FlutterSwift) and [SwiftOCA](https://github.com/PADL/SwiftOCA). OCP.1 values are re-encoded using the chosen Flutter codec.

Once Swift Package Manager is [merged](https://github.com/flutter/flutter/pull/146256) into Flutter, this package will become a Flutter plugin with a Dart API and some example widgets for common OCA controls. Until then you will need to add an explicit dependency to your Xcode project and implement the widgets according to the channel protocol below.

Method channel
---------------

* Channel is `oca/method`
* Method syntax is `<hex-ono>/<dotted-method-id>` (with no leading 0x)
* Arguments are `List<Uint8List>` where each item is an encoded parameter to be passed to the OCA device
* Return value is [UInt8]. The response parameter count is not returned.

This will mostly be useful for testing, unless you wish to build your own OCP.1 serializers in Dart.

Event channel
-------------

* Channel is `oca/event`
* Listener parameter is `<hex-ono>/<dotted-property-id>`
* Event data is the encoded property value

Get property channel
--------------------

* Channel is `oca/get_property`
* Listener parameter is `<hex-ono>/<dotted-property-id>`
* Arguments are null
* Return value is the encoded property value

Set property channel
--------------------

* Channel is `oca/set_property`
* Listener parameter is `<hex-ono>/<dotted-property-id>`
* Arguments are the encoded property value
* Return value is null

Connection state channel
------------------------

* Channel is `oca/connection_state`
* Listener parameter is ignored
* Event data is `Ocp1ConnectionState` integer raw value

