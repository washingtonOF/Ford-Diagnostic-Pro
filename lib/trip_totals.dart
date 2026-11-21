class TripTotals {
  const TripTotals({
    this.distance = 0,
    this.liters = 0,
    this.cost = 0,
    this.seconds = 0,
    this.stoppedSeconds = 0,
    this.fuelSeconds = 0,
    this.pricedLiters = 0,
    this.fuelDistance = 0,
  });

  final double distance, liters, cost, seconds, stoppedSeconds, fuelSeconds, pricedLiters, fuelDistance;

  double? get averageSpeed => seconds > 0 ? distance * 3600 / seconds : null;
  double? get consumption => fuelDistance > 0 && fuelSeconds > 0 ? liters * 100 / fuelDistance : null;
  double? get fuelCost => fuelSeconds > 0 && (liters - pricedLiters).abs() < 0.000001 ? cost : null;

  TripTotals operator +(TripTotals other) => TripTotals(
    distance: distance + other.distance, liters: liters + other.liters,
    cost: cost + other.cost, seconds: seconds + other.seconds,
    stoppedSeconds: stoppedSeconds + other.stoppedSeconds,
    fuelSeconds: fuelSeconds + other.fuelSeconds, pricedLiters: pricedLiters + other.pricedLiters,
    fuelDistance: fuelDistance + other.fuelDistance,
  );

  Map<String, double> toJson() => {
    'distance': distance, 'liters': liters, 'cost': cost, 'seconds': seconds,
    'stoppedSeconds': stoppedSeconds, 'fuelSeconds': fuelSeconds, 'pricedLiters': pricedLiters,
    'fuelDistance': fuelDistance,
  };

  factory TripTotals.fromJson(Map<String, dynamic> json) {
    double read(String key) => (json[key] as num?)?.toDouble() ?? 0;
    return TripTotals(
      distance: read('distance'), liters: read('liters'), cost: read('cost'), seconds: read('seconds'),
      stoppedSeconds: read('stoppedSeconds'), fuelSeconds: read('fuelSeconds'),
      pricedLiters: read('pricedLiters'), fuelDistance: read('fuelDistance'),
    );
  }

  factory TripTotals.sample(double seconds, double speed, double? litersPerHour, double? price) {
    final distance = speed * seconds / 3600;
    final liters = (litersPerHour ?? 0) * seconds / 3600;
    return TripTotals(
      distance: distance, liters: liters, cost: liters * (price ?? 0),
      seconds: seconds, stoppedSeconds: speed == 0 ? seconds : 0,
      fuelSeconds: litersPerHour == null ? 0 : seconds,
      pricedLiters: price == null ? 0 : liters,
      fuelDistance: litersPerHour == null ? 0 : distance,
    );
  }
}
