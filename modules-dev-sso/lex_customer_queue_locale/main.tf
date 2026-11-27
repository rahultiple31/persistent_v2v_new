module "custom_intents" {
  source = "../lex_yes_no_locale"

  configuration = merge(var.configuration, {
    intents = {
      repeat = [
        "répète",
        "pourrais-tu répéter?",
        "répète, s’il te plaît",
        "peux-tu répéter ça?",
        "redis-le",
        "pourrais-tu répéter, s’il te plaît?",
        "répète la question",
        "je n’ai pas entendu ça",
        "j’ai raté ça",
        "qu’est-ce que c’était?",
        "pardon",
        "peux-tu redire ça?",
      ]

      virtualQueue = [
        "file d'attente virtuelle",
        "rappel",
        "rappelez-moi",
        "Je veux qu'on me rappelle",
        "demander un rappel",
        "garder ma place dans la file d'attente",
        "conserver ma position dans la file d'attente",
        "enregistrer ma place dans la file d'attente",
        "que quelqu'un me rappelle",
        "rappel, s'il vous plaît",
      ]

      voicemail = [
        "messagerie vocale",
        "laisser un message vocal",
        "Je veux laisser un message vocal",
        "laissez-moi laisser un message",
        "laisser un message",
        "prendre un message",
        "envoyer un message vocal",
        "enregistrer un message",
        "J’aimerais laisser un message",
        "messagerie vocale, s’il vous plaît",
      ]
    }
  })
}
