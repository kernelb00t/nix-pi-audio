# Parametric EQ via PipeWire filter-chain.
#
# Reproduces the "Lo Boost" curve that was running on Moode Audio (alsaequal /
# CAPS Eq10): a bass shelf that adds +12.24 dB at 31 Hz and +4.32 dB at 63 Hz,
# relative to the flat reference.  A preamp of -12.24 dB prevents clipping.
#
# The EQ is inserted as a virtual sink that every client (Soloist, AirPlay,
# Bluetooth) routes through automatically thanks to the WirePlumber default-sink
# rule below.
{ lib, settings, ... }:
let
  eqEnabled = settings ? equalizer && settings.equalizer.enable or false;
  bands = settings.equalizer.bands or [];

  # Build the filter-chain nodes: a preamp followed by one bq_peaking per band.
  preampNode = {
    type = "builtin";
    name = "preamp";
    label = "bq_highshelf";
    control = {
      "Freq" = 0.0;
      "Q" = 1.0;
      "Gain" = settings.equalizer.preamp or 0.0;
    };
  };

  bandNodes = lib.imap0 (i: band: {
    type = "builtin";
    name = "eq_band_${toString i}";
    label = "bq_peaking";
    control = {
      "Freq" = band.freq;
      "Q" = band.q or 1.41;
      "Gain" = band.gain;
    };
  }) bands;

  allNodes = [ preampNode ] ++ bandNodes;

  # Sequential links: preamp → band0 → band1 → …
  nodeNames = map (n: n.name) allNodes;
  linkPairs = lib.zipListsWith (a: b: { from = a; to = b; })
    (lib.init nodeNames) (lib.tail nodeNames);

  links = lib.concatMap (pair: [
    { output = "${pair.from}:Out 1"; input = "${pair.to}:In 1"; }
    { output = "${pair.from}:Out 2"; input = "${pair.to}:In 2"; }
  ]) linkPairs;

  lastNode = lib.last nodeNames;
in
{
  config = lib.mkIf eqEnabled {
    services.pipewire.extraConfig.pipewire."90-equalizer" = {
      "context.modules" = [
        {
          name = "libpipewire-module-filter-chain";
          args = {
            "node.description" = "Equalizer";
            "media.name" = "Equalizer";
            "filter.graph" = {
              nodes = allNodes;
              inherit links;
              inputs = [ "preamp:In 1" "preamp:In 2" ];
              outputs = [ "${lastNode}:Out 1" "${lastNode}:Out 2" ];
            };
            "audio.position" = [ "FL" "FR" ];
            "capture.props" = {
              "node.name" = "effect_input.eq";
              "media.class" = "Audio/Sink";
            };
            "playback.props" = {
              "node.name" = "effect_output.eq";
              "node.passive" = true;
            };
          };
        }
      ];
    };

    # Make the EQ sink the default output so every client routes through it.
    services.pipewire.wireplumber.extraConfig."90-equalizer-default"."monitor.alsa.rules" = [
      {
        matches = [ { "node.name" = "effect_input.eq"; } ];
        actions.update-props = {
          "priority.session" = 2000;
          "priority.driver" = 2000;
        };
      }
    ];
  };
}
