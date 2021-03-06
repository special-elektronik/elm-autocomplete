module Autocomplete exposing
    ( Autocomplete, Config
    , init
    , update, setSuggestions, Msg
    , input, toView
    )

{-| An opinionated autocomplete component that fits our needs. It's broken into its own package because we need to use it in multiple applications. The autocomplete waits for at least 3 characters and 200 milliseconds before any command is triggered.


# State

@docs Autocomplete, Config


# Initialize

@docs init


# Update

@docs update, setSuggestions, Msg


# View

@docs input, toView

-}

import Debounce exposing (Debounce)
import Html exposing (Attribute, Html)
import Html.Attributes as Attributes
import Html.Events as Events
import Json.Decode as Decode
import Task


{-| The components internal state, the parameter `a` is the type of suggestions that you would like the autocomplete to return. It could be as simple as a string och any other type you'd like.
-}
type Autocomplete a
    = Autocomplete (Internals a)


type alias Internals a =
    { query : String
    , suggestions : List a
    , index : Maybe Int
    , debounce : Debounce String
    }


{-| Opaque type for internal messages
-}
type Msg
    = GotQuery String
    | GotFocus
    | LoadSuggestions String
    | Submitted
    | DebounceMsg Debounce.Msg
    | GotArrowKey ArrowKey
    | NoOp


type ArrowKey
    = Up
    | Down


{-| The Autocomplete needs a config:

  - **transform**: Into what Msg should be encode all internal autocomplete messages to?

  - **fetch**: The autocomplete let your application handle the fetching of suggestions. Supply a function that takes a string and returns a Command. To store the suggestions, call `setSuggestions` when the command completes with an OK.

  - **submit**: The message that will be triggered when the user submits a query. Perhaps you want to send the user to a search result page? This does not means that there is a matching suggestion. Imagine the user enters "Karls" and the suggestions return "Karlstad" and "Karlshamn" but the user really want to search for "Karlslund"

  - **chose**: The message that will be triggered when the user chooses a suggestion

  - **focus**: The message what will be triggered when the user focuses in the input element.

-}
type alias Config a msg =
    { transform : Msg -> msg
    , fetch : String -> Cmd msg
    , submit : String -> msg
    , chose : a -> msg
    , focus : msg
    }


{-| This defines how the debouncer should work.
Choose the strategy for your use case.
-}
debounceConfig : Debounce.Config Msg
debounceConfig =
    { strategy = Debounce.later 200
    , transform = DebounceMsg
    }


{-| Initialize the component with an optional query
-}
init : String -> Autocomplete a
init q =
    Autocomplete { query = q, suggestions = [], index = Nothing, debounce = Debounce.init }


{-| Update the Autocomplete and optionally return a Msg that the parent function should issue.

NOTE: If the maybeMsg is Just, than the cmd must be Cmd.none and ignored by the parent function.

-}
update : Config a msg -> Msg -> Autocomplete a -> { newAutocomplete : Autocomplete a, maybeMsg : Maybe msg, cmd : Cmd msg }
update config msg (Autocomplete internals) =
    case msg of
        GotQuery q ->
            if String.length q < 3 then
                { newAutocomplete =
                    Autocomplete
                        { internals
                            | query = q
                            , suggestions = []
                            , index = Nothing
                        }
                , maybeMsg = Nothing
                , cmd = Cmd.none
                }

            else
                let
                    ( debounce, cmd ) =
                        Debounce.push debounceConfig q internals.debounce
                in
                { newAutocomplete =
                    Autocomplete
                        { internals
                            | query = q
                            , debounce = debounce
                        }
                , maybeMsg = Nothing
                , cmd = Cmd.map config.transform cmd
                }

        GotFocus ->
            { newAutocomplete = Autocomplete internals
            , maybeMsg = Just config.focus
            , cmd = Cmd.none
            }

        DebounceMsg subMsg ->
            let
                ( debounce, cmd ) =
                    Debounce.update
                        debounceConfig
                        (Debounce.takeLast load)
                        subMsg
                        internals.debounce
            in
            { newAutocomplete = Autocomplete { internals | debounce = debounce }
            , maybeMsg = Nothing
            , cmd = Cmd.map config.transform cmd
            }

        LoadSuggestions q ->
            { newAutocomplete = Autocomplete internals
            , maybeMsg = Nothing
            , cmd = config.fetch q
            }

        Submitted ->
            let
                ( newMsg, newQuery ) =
                    case ( internals.index, internals.query ) of
                        ( Nothing, "" ) ->
                            -- "Do nothing if the search bar is empty"
                            ( Nothing, "" )

                        ( Nothing, q ) ->
                            ( Just (config.submit q), q )

                        ( Just i, _ ) ->
                            ( getAt i internals.suggestions
                                |> Maybe.map config.chose
                            , ""
                            )
            in
            { newAutocomplete = Autocomplete { internals | index = Nothing, query = newQuery }
            , maybeMsg = newMsg
            , cmd = Cmd.none
            }

        GotArrowKey upOrDown ->
            case internals.suggestions of
                [] ->
                    ignoreUpdate internals

                _ ->
                    let
                        newIndex =
                            case ( upOrDown, internals.index ) of
                                ( Down, Nothing ) ->
                                    Just 0

                                ( Up, Nothing ) ->
                                    Just (modBy (List.length internals.suggestions) -1)

                                ( Down, Just i ) ->
                                    Just (modBy (List.length internals.suggestions) (i + 1))

                                ( Up, Just 0 ) ->
                                    Nothing

                                ( Up, Just i ) ->
                                    Just (modBy (List.length internals.suggestions) (i - 1))
                    in
                    { newAutocomplete = Autocomplete { internals | index = newIndex }
                    , maybeMsg = Nothing
                    , cmd = Cmd.none
                    }

        NoOp ->
            ignoreUpdate internals


ignoreUpdate : Internals a -> { newAutocomplete : Autocomplete a, maybeMsg : Maybe msg, cmd : Cmd msg }
ignoreUpdate internals =
    { newAutocomplete = Autocomplete internals
    , maybeMsg = Nothing
    , cmd = Cmd.none
    }


load : String -> Cmd Msg
load q =
    Task.perform LoadSuggestions (Task.succeed q)


{-| Update the component with your suggestions
-}
setSuggestions : List a -> Autocomplete a -> Autocomplete a
setSuggestions suggestions (Autocomplete internals) =
    Autocomplete { internals | suggestions = suggestions }


{-| Retrieve values intented for the view. The index field potentially holds the index of the selected suggestion.
-}
toView : Autocomplete a -> { query : String, suggestions : List a, index : Maybe Int }
toView (Autocomplete internals) =
    { query = internals.query
    , suggestions = internals.suggestions
    , index = internals.index
    }


{-| View the input tag
-}
input : Config a msg -> List (Attribute Never) -> Autocomplete a -> Html msg
input config attrs (Autocomplete { query }) =
    Html.input
        (List.map mapNeverToMsg attrs
            ++ [ Events.onInput GotQuery
               , Events.onFocus GotFocus
               , handleEnterOrArrowUpOrDown
               , Attributes.value query
               ]
        )
        []
        |> Html.map config.transform



-- HELPERS
-- Copied from https://github.com/thebritican/elm-autocomplete/blob/3d10dc37479b594815c43f79f772b09c1e5d37c3/src/Autocomplete/Autocomplete.elm#L452


mapNeverToMsg : Attribute Never -> Attribute Msg
mapNeverToMsg msg =
    Attributes.map (\_ -> NoOp) msg


handleEnterOrArrowUpOrDown : Attribute Msg
handleEnterOrArrowUpOrDown =
    let
        isEnter code =
            case code of
                13 ->
                    Decode.succeed Submitted

                38 ->
                    Decode.succeed (GotArrowKey Up)

                40 ->
                    Decode.succeed (GotArrowKey Down)

                _ ->
                    Decode.fail "not ENTER"
    in
    Events.on "keydown" (Decode.andThen isEnter Events.keyCode)


{-| List.getAt
<https://github.com/elm-community/list-extra/blob/7.1.0/src/List/Extra.elm#L186>
Returns `Just` the element at the given index in the list,
or `Nothing` if the index is out of range.
-}
getAt : Int -> List a -> Maybe a
getAt idx xs =
    if idx < 0 then
        Nothing

    else
        List.head <| List.drop idx xs
