# Léo's room: HiFiBerry Amp2.
{
  hostName = "chambre-de-leo";
  deviceName = "Chambre de Léo";
  audioOutput = "hifiberry-amp2";

  # Parametric EQ migrated from Moode Audio's "Lo Boost" curve (alsaequal / CAPS
  # Eq10).  The original 10-band graphic EQ had +12.24 dB at 31 Hz and +4.32 dB
  # at 63 Hz relative to flat; all other bands were flat.  Only the non-zero
  # bands are listed here; the preamp compensates for the highest boost.
  equalizer = {
    enable = true;
    preamp = -12.24;
    bands = [
      { freq = 31.0;  q = 1.41; gain = 12.24; }
      { freq = 63.0;  q = 1.41; gain = 4.32;  }
    ];
  };
}
