defmodule Relay.Phone do
  @moduledoc """
  Phone numbers in E.164 form: `+`, a country code that does not start with zero and at most 15 digits in all. A Turkish number written with its trunk zero (`+900…`) is refused. The accepted number is a contact address and is returned wrapped in `Relay.Redacted`.
  """

  @e164 ~r/\A\+[1-9][0-9]{1,14}\z/

  @calling_codes ~w(
    20:EG 27:ZA 30:GR 31:NL 32:BE 33:FR 34:ES 36:HU 39:IT 40:RO 41:CH 43:AT 44:GB 45:DK 46:SE
    47:NO 48:PL 49:DE 51:PE 52:MX 53:CU 54:AR 55:BR 56:CL 57:CO 58:VE 60:MY 61:AU 62:ID 63:PH
    64:NZ 65:SG 66:TH 81:JP 82:KR 84:VN 86:CN 90:TR 91:IN 92:PK 93:AF 94:LK 95:MM 98:IR 211:SS
    212:MA 213:DZ 216:TN 218:LY 220:GM 221:SN 222:MR 223:ML 224:GN 225:CI 226:BF 227:NE 228:TG
    229:BJ 230:MU 231:LR 232:SL 233:GH 234:NG 235:TD 236:CF 237:CM 238:CV 239:ST 240:GQ 241:GA
    242:CG 243:CD 244:AO 245:GW 246:IO 248:SC 249:SD 250:RW 251:ET 252:SO 253:DJ 254:KE 255:TZ
    256:UG 257:BI 258:MZ 260:ZM 261:MG 262:RE 263:ZW 264:NA 265:MW 266:LS 267:BW 268:SZ 269:KM
    290:SH 291:ER 297:AW 298:FO 299:GL 350:GI 351:PT 352:LU 353:IE 354:IS 355:AL 356:MT 357:CY
    358:FI 359:BG 370:LT 371:LV 372:EE 373:MD 374:AM 375:BY 376:AD 377:MC 378:SM 380:UA 381:RS
    382:ME 385:HR 386:SI 387:BA 389:MK 420:CZ 421:SK 423:LI 500:FK 501:BZ 502:GT 503:SV 504:HN
    505:NI 506:CR 507:PA 508:PM 509:HT 590:GP 591:BO 592:GY 593:EC 594:GF 595:PY 596:MQ 597:SR
    598:UY 599:CW 670:TL 672:NF 673:BN 674:NR 675:PG 676:TO 677:SB 678:VU 679:FJ 680:PW 681:WF
    682:CK 683:NU 685:WS 686:KI 687:NC 688:TV 689:PF 690:TK 691:FM 692:MH 850:KP 852:HK 853:MO
    855:KH 856:LA 880:BD 886:TW 960:MV 961:LB 962:JO 963:SY 964:IQ 965:KW 966:SA 967:YE 968:OM
    970:PS 971:AE 972:IL 973:BH 974:QA 975:BT 976:MN 977:NP 992:TJ 993:TM 994:AZ 995:GE 996:KG
    998:UZ
  )

  @countries Map.new(@calling_codes, &List.to_tuple(String.split(&1, ":")))

  # OP-1
  # T-58
  @doc "Validates an E.164 phone number and returns it redacted."
  @spec new(String.t() | Relay.Redacted.t()) ::
          {:ok, Relay.Redacted.t()} | {:error, Relay.Error.t()}
  def new(number) do
    if Relay.Redacted.redacted?(number),
      do: number |> Relay.Redacted.expose() |> validate(),
      else: validate(number)
  end

  # OP-38
  @doc "The country of an E.164 number from its country calling code, as an ISO 3166-1 alpha-2 code; `nil` for a code that several countries share (`+1`, `+7`) or that names no country."
  @spec country(String.t()) :: String.t() | nil
  def country("+" <> digits) do
    Map.get(@countries, String.slice(digits, 0, 3)) ||
      Map.get(@countries, String.slice(digits, 0, 2))
  end

  def country(_number), do: nil

  defp validate(number) when is_binary(number) do
    cond do
      not Regex.match?(@e164, number) -> invalid("not an E.164 number")
      String.starts_with?(number, "+900") -> invalid("Turkish number with a trunk zero")
      true -> {:ok, Relay.Redacted.wrap(number)}
    end
  end

  defp validate(_other), do: invalid("not an E.164 number")

  defp invalid(message), do: {:error, Relay.Error.new(:invalid_phone, message)}
end
