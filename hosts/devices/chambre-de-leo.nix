# Léo's room: HiFiBerry Amp2.
{
  hostName = "chambre-de-leo";
  deviceName = "Chambre de Léo";
  audioOutput = "hifiberry-amp2";

  # Parametric EQ migrated from Moode Audio's "Lo Boost" curve (alsaequal / CAPS
  # Eq10). In Moode, the flat reference was at -4.80 dB, 31 Hz at +7.44 dB
  # (+12.24 dB relative), and 63 Hz at -0.48 dB (+4.32 dB relative).
  # Setting preamp to -4.80 dB matches Moode's overall gain structure.
  equalizer = {
    enable = true;
    preamp = -4.80;
    bands = [
      { freq = 31.0;  q = 1.41; gain = 12.24; }
      { freq = 63.0;  q = 1.41; gain = 4.32;  }
    ];
  };
}
