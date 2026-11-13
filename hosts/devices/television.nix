# TV room: HiFiBerry Digi S/PDIF to Onkyo receiver.
{
  hostName = "television";
  deviceName = "Télévision";
  audioOutput = "hifiberry-digi";

  # Onkyo AV receiver integration over eISCP.
  # The receiver will be auto-discovered over the network (UDP broadcast),
  # or configured via ONKYO_HOST in soloist.env.
  onkyo.enable = true;
}
