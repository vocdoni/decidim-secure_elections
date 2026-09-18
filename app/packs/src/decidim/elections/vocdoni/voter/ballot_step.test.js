/* global jest */

import { buildBallot, byId, i18n, question, visible } from "src/decidim/elections/vocdoni/voter/voting_page_fixture";

/**
 * What the ballot *tells* the voter, as opposed to what it does.
 *
 * Both of these came out of a real interruption: a voter closed the tab after
 * question 1 had been recorded and before question 2 was, then came back and
 * identified again. The voting page resumed correctly — that behaviour is not what is
 * tested here, and not what changed — but it described the resume wrongly, in a
 * situation where the voter has every reason to be anxious about it.
 */

const questions = () => [
  question({ vocdoniQuestionId: "q1", title: "Should we adopt the budget?" }),
  question({ vocdoniQuestionId: "q2", title: "Which fixes matter most?" })
];

/**
 * A voter who was interrupted: question 1 is already on the network.
 *
 * @returns {Object[]} the election's questions, question 1 already recorded.
 */
const resumed = () => {
  const list = questions();

  list[0].hasVoted = true;
  list[0].canVote = false;

  return list;
};

const status = () => byId("js-vocdoni-vote-status").textContent;

const counter = () => byId("js-vocdoni-ballot-counter").textContent;

const legendNumber = (index) => document.
  querySelector(`[data-question-index="${index}"] legend .vocdoni-visually-hidden`).textContent.trim();

const answer = (index) => {
  document.querySelector(`#vocdoni-answer-${index}-0`).checked = true;
};

const advance = () => byId("js-vocdoni-ballot-next").click();

afterEach(() => {
  jest.useRealTimers();
  document.body.innerHTML = "";
});

describe("a ballot the voter is resuming", () => {
  // The bug: the counter numbered the questions by their position in *this*
  // voter's shortened ballot, the legend by their position in the election. One
  // question, two numbers, on the same screen.
  it("numbers the question the same way in the counter and in its legend", () => {
    const { step } = buildBallot(resumed());

    step.start([1]);

    expect(counter()).toBe("Question 2 of 2");
    expect(legendNumber(1)).toBe("Question 2:");
  });

  it("keeps numbering questions by the election when nothing was recorded", () => {
    const { step } = buildBallot(questions());

    step.start([0, 1]);

    expect(counter()).toBe("Question 1 of 2");
    expect(legendNumber(0)).toBe("Question 1:");

    answer(0);
    advance();

    expect(counter()).toBe("Question 2 of 2");
    expect(legendNumber(1)).toBe("Question 2:");
  });

  it("says that part of the ballot is already recorded, and which part", () => {
    const { step } = buildBallot(resumed());

    step.start([1]);

    const notice = document.querySelector("#js-vocdoni-step-ballot [data-recorded-notice]");

    expect(visible(notice)).toBe(true);
    expect(notice.querySelector("[data-recorded-title]").textContent).
      toBe(i18n.ballot.already_recorded.title);

    const recorded = notice.querySelectorAll("[data-recorded-question]");

    expect(recorded).toHaveLength(1);
    expect(recorded[0].textContent).toBe("Question 1: Should we adopt the budget?");
  });

  // The notice sits above the fieldset, and focus goes to the fieldset's legend,
  // so reading forward from focus never reaches it.
  it("announces the resume, so it is not only reachable by reading backwards", () => {
    const { step, ui } = buildBallot(resumed());

    step.start([1]);

    expect(ui.announce).toHaveBeenCalledWith(i18n.ballot.already_recorded.title);
  });

  it("says nothing of the sort to a voter with a whole ballot in front of them", () => {
    const { step, ui } = buildBallot(questions());

    step.start([0, 1]);

    expect(visible(document.querySelector("#js-vocdoni-step-ballot [data-recorded-notice]"))).toBe(false);
    expect(ui.announce).not.toHaveBeenCalled();
  });
});

describe("the review screen of a resumed ballot", () => {
  const reachReview = (list, indexes) => {
    const built = buildBallot(list);

    built.step.start(indexes);
    indexes.forEach((index) => {
      answer(index);
      advance();
    });

    return built;
  };

  // "Nothing has been sent yet" is simply false for a voter whose earlier vote
  // is on the network and whose receipt for it appears two screens later.
  it("does not claim nothing has been sent when something has", () => {
    reachReview(resumed(), [1]);

    expect(byId("js-vocdoni-review-body").textContent).toBe(i18n.review.body_partial);
    expect(byId("js-vocdoni-review-body").textContent).not.toBe(i18n.review.body);
  });

  it("still reassures the voter who really has sent nothing", () => {
    reachReview(questions(), [0, 1]);

    expect(byId("js-vocdoni-review-body").textContent).toBe(i18n.review.body);
    expect(visible(document.querySelector("#js-vocdoni-step-review [data-recorded-notice]"))).toBe(false);
  });

  it("names the recorded questions again, next to the answers still to send", () => {
    reachReview(resumed(), [1]);

    const notice = document.querySelector("#js-vocdoni-step-review [data-recorded-notice]");

    expect(visible(notice)).toBe(true);
    expect(notice.querySelector("[data-recorded-question]").textContent).
      toBe("Question 1: Should we adopt the budget?");
    // Only what is left is up for review; the recorded question is not offered
    // for editing.
    expect(document.querySelectorAll("#js-vocdoni-review-list li")).toHaveLength(1);
  });
});

describe("the status line during the ballot", () => {
  // A voter who fixes what they were told to fix must not then be greeted by
  // the message telling them to fix it. Error noise on a voting surface teaches
  // voters to ignore the one channel that later carries a real failure.
  it("stops repeating a validation error the voter has already acted on", () => {
    const { step } = buildBallot(questions());

    step.start([0, 1]);
    advance();

    expect(status()).toBe(i18n.validation.required);

    answer(0);
    advance();

    expect(status()).toBe("");
    expect(counter()).toBe("Question 2 of 2");
  });

  it("clears it on the way to the review as well", () => {
    const { step } = buildBallot(questions());

    step.start([0, 1]);
    answer(0);
    advance();
    advance();

    expect(status()).toBe(i18n.validation.required);

    answer(1);
    advance();

    expect(status()).toBe("");
    expect(visible(byId("js-vocdoni-step-review"))).toBe(true);
  });

  it("clears it when the voter steps back rather than forward", () => {
    const { step } = buildBallot(questions());

    step.start([0, 1]);
    answer(0);
    advance();
    advance();

    expect(status()).toBe(i18n.validation.required);

    byId("js-vocdoni-ballot-back").click();

    expect(status()).toBe("");
  });
});
