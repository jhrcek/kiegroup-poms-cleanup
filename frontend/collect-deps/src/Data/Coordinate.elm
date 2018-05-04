module Data.Coordinate exposing (Coordinate, decoder, toString)

import Json.Decode as Decode exposing (Decoder, string)
import Json.Decode.Pipeline exposing (decode, optional, required)


type alias Coordinate =
    { groupId : String
    , artifactId : String
    , packaging : String
    , qualifier : Maybe String
    , version : String
    }


decoder : Decoder Coordinate
decoder =
    decode Coordinate
        |> required "gr" string
        |> required "ar" string
        |> required "pa" string
        |> optional "qu" (Decode.map Just string) Nothing
        |> required "ve" string


toString : Coordinate -> String
toString c =
    let
        fields =
            case c.qualifier of
                Nothing ->
                    [ c.groupId, c.artifactId, c.packaging, c.version ]

                Just qualifier ->
                    [ c.groupId, c.artifactId, c.packaging, qualifier, c.version ]
    in
    String.join ":" fields
