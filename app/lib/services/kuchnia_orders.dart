/// Walks the panel's endpoints to a day's delivered dishes.
///
/// The Dart mirror of `diet_guard/_kuchnia_orders.py`. Three calls, and the
/// shape of the walk is not what the endpoint names suggest:
///
/// 1. `company/customer/order/active-ids` -> `[orderId, ...]`. More than one
///    while a renewal overlaps the running order, **newest first** -- so the
///    first id is the future order and today's delivery sits in a later one.
/// 2. `company/customer/order/{orderId}` -> the order, which **embeds every
///    delivery** with its date. No enumeration call is needed, but the
///    embedded `deliveryMeals` carry ids only -- no names, no macros.
/// 3. `company/general/menus/delivery/{deliveryId}/new` -> the day's actual
///    menu, with names and per-portion nutrition.
///
/// Step 3 is the important correction: the obvious-looking
/// `.../deliveries/{id}/details` **404s** (and 400s when keyed by date),
/// confirmed against three separate delivery days. The menu endpoint is keyed
/// by the opaque `deliveryId`, never by the date.
library;

import 'package:diet_guard_app/models/kuchnia_dish.dart';
import 'package:diet_guard_app/services/kuchnia_client.dart';
import 'package:diet_guard_app/services/kuchnia_errors.dart';
import 'package:diet_guard_app/services/kuchnia_parse.dart';

/// Returns every active order id, empty when there is no active order.
List<Object?> activeOrderIds(Object? payload) {
  if (payload is! List) return const [];
  return payload;
}

/// Returns the delivery id whose date is [wanted] (an ISO `YYYY-MM-DD`).
///
/// Null when that day has no delivery, or only a cancelled one -- a `deleted`
/// delivery still appears in the list.
Object? deliveryIdFor(Object? payload, String wanted) {
  if (payload is! Map) return null;
  final deliveries = payload['deliveries'];
  if (deliveries is! List) return null;
  for (final delivery in deliveries) {
    if (delivery is! Map) continue;
    if (delivery['deleted'] == true) continue;
    if ('${delivery['date']}' == wanted) return delivery['deliveryId'];
  }
  return null;
}

/// Formats [day] as the ISO `YYYY-MM-DD` the panel keys deliveries by.
String isoDay(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// Returns the dishes delivered on [day], empty when nothing is delivered.
///
/// Throws [KuchniaError] when the panel cannot be read, or when a delivery
/// exists but nothing survived parsing -- either the menu is not published yet
/// or its units failed the consistency check. Both are "no data", but they are
/// worth distinguishing from "no delivery" in the caller's message.
Future<List<KuchniaDish>> fetchDishes(
  KuchniaSession session,
  DateTime day,
) async {
  final orderIds = activeOrderIds(await session.getJson(
    'company/customer/order/active-ids',
  ));
  final wanted = isoDay(day);
  // Never trust the list's order: on 2026-10-10 a renewal starting 10-24
  // came first, and reading only it made every day look delivery-free.
  Object? deliveryId;
  for (final orderId in orderIds) {
    final order = await session.getJson('company/customer/order/$orderId');
    deliveryId = deliveryIdFor(order, wanted);
    if (deliveryId != null) break;
  }
  if (deliveryId == null) return const [];

  final menu = await session.getJson(
    'company/general/menus/delivery/$deliveryId/new',
  );
  final dishes = parseMenu(menu);
  if (dishes.isEmpty) {
    throw KuchniaError('catering menu for $wanted has no usable dishes');
  }
  return dishes;
}
